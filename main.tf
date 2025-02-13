locals {
  user_data_script = <<-EOF
              #!/bin/bash
              set -x
              sudo su - <<EOF2
              set -x
              sudo amazon-linux-extras install ecs -y
              systemctl enable amazon-ssm-agent
              systemctl start amazon-ssm-agent
              echo "ECS_CLUSTER=${aws_ecs_cluster.jenkins_cluster.name}"
              cd /etc/ecs/
              touch ecs.config
              echo "ECS_CLUSTER=${aws_ecs_cluster.jenkins_cluster.name}" >> /etc/ecs/ecs.config
              chmod 755 ecs.config
              systemctl restart docker
              systemctl disable --now --no-block ecs
              systemctl start ecs
              systemctl status ecs
              if systemctl is-active --quiet ecs; then
                  echo "ECS service is running"
              else
                  echo "ECS service is not running, starting service..."
                  systemctl restart ecs
              fi
              EOF2
              EOF
}

resource "aws_ecs_cluster" "jenkins_cluster" {
  name = "jenkins-cluster"
}

resource "aws_cloudwatch_log_group" "jenkins_log_group" {
  name              = "/ecs/jenkins"
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "jenkins_master_task" {
  family                   = "jenkins-master"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  cpu                      = "128"
  memory                   = "256"

  container_definitions = jsonencode([
    {
      name      = "jenkins-master"
      image     = "jenkins/jenkins:lts"
      essential = true
      task_role_arn = aws_iam_role.ecs_task_instance_role.arn
      execution_role_arn = aws_iam_role.ecs_task_instance_role.arn
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.jenkins_log_group.name
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "jenkins_master_service" {
  name            = "jenkins-master-service"
  cluster         = aws_ecs_cluster.jenkins_cluster.id
  task_definition = aws_ecs_task_definition.jenkins_master_task.arn
  desired_count   = 1
  launch_type     = "EC2"
  
  network_configuration {
    subnets         = ["subnet-6960e648", "subnet-1fa82c40"]
    security_groups = ["sg-0ca22c73e7506a0f0", "sg-0cd70ecf61463c2e9"]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.jenkins_tg.arn
    container_name   = "jenkins-master"
    container_port   = 8080
  }
}

resource "aws_launch_template" "jenkins_lt" {
  name          = "jenkins-lt"
  image_id      = "ami-04681163a08179f28" // Amazon Linux 2 AMI
  instance_type = "t2.micro"
  key_name = "local-login"
  
  network_interfaces {
    associate_public_ip_address = true // allow pubpic ip
    security_groups = ["sg-0ca22c73e7506a0f0", "sg-0cd70ecf61463c2e9"]
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

  user_data = base64encode(local.user_data_script)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "jenkins_asg" {
  launch_template {
    id      = aws_launch_template.jenkins_lt.id
    version = "$Latest"
  }
  min_size             = 1
  max_size             = 1
  desired_capacity     = 1
  vpc_zone_identifier  = ["subnet-6960e648"]

  tag {
    key                 = "Name"
    value               = "jenkins-ecs-instance"
    propagate_at_launch = true
  }
  
  lifecycle {
    create_before_destroy = true
  }

}

resource "aws_lb" "jenkins_lb" {
  name               = "jenkins-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["sg-0bb4647ebf01edb61","sg-064f2dc0823276142"]
  subnets            = ["subnet-6960e648", "subnet-1fa82c40"]
}

resource "aws_lb_target_group" "jenkins_tg" {
  name         = "jenkins-tg"
  port         = 8080
  protocol     = "HTTP"
  vpc_id       = "vpc-1d9f4860"
  target_type  = "ip"
  health_check {
    path                = "/"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "jenkins_listener" {
  load_balancer_arn = aws_lb.jenkins_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jenkins_tg.arn
  }
}

resource "aws_appautoscaling_target" "jenkins_master_service_ac" {
  max_capacity       = 1
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.jenkins_cluster.name}/${aws_ecs_service.jenkins_master_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs_instance_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = ["ec2.amazonaws.com", "ecs.amazonaws.com"]
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}
resource "aws_iam_role" "ecs_task_instance_role" {
  name = "ecs_task_instance_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "ecs_task_execution_policy" {
  name   = "ecs_task_execution_policy"
  policy = jsonencode({
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:*",
        "ecr:*"
    ],
      "Resource": "*"
  }
 ]
})
}

resource "aws_iam_role_policy_attachment" "ecs_task_instance_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = aws_iam_policy.ecs_task_execution_policy.arn
}

resource "aws_iam_role_policy_attachment" "ecs_task_role_instance_role_policy" {
  role       = aws_iam_role.ecs_task_instance_role.name
  policy_arn = aws_iam_policy.ecs_task_execution_policy.arn
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "ecs_task_exec_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ssm_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_instance_connect_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceConnect"
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs_instance_profile"
  role = aws_iam_role.ecs_instance_role.name
}

output "jenkins_url" {
  value       = aws_lb.jenkins_lb.dns_name
  description = "The DNS name of the Jenkins load balancer"
}