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
              echo "ECS_ENABLE_TASK_IAM_ROLE=true" >> /etc/ecs/ecs.config
              echo "ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true" >> /etc/ecs/ecs.config
              echo "ECS_AVAILABLE_LOGGING_DRIVERS=[\"awslogs\"]" >> /etc/ecs/ecs.config
              echo "ECS_VOLUME_PLUGIN_ENABLED=true" >> /etc/ecs/ecs.config
              chmod 755 ecs.config
              sudo yum install -y amazon-efs-utils
              sudo yum install -y python3-pip
              pip3 install botocore
              systemctl enable --now amazon-ecs-volume-plugin
              service ecs stop
              service ecs start
              EOF2
              EOF
}
resource "aws_route_table" "public-rt" {
  vpc_id = "vpc-1d9f4860"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "igw-8b7e44f0" // Internet gateway
  }
}

resource "aws_route_table_association" "public-rt" {
  subnet_id      = "subnet-1fa82c40" // Public subnet
  route_table_id = aws_route_table.public-rt.id
}

resource "aws_route_table_association" "public-rt2" {
  subnet_id      = "subnet-eb33fcda" // Public subnet
  route_table_id = aws_route_table.public-rt.id
}


resource "aws_route_table" "private-rt" {
  vpc_id = "vpc-1d9f4860"

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private-rt1" {
  subnet_id      = "subnet-6960e648" // Private subnet
  route_table_id = aws_route_table.private-rt.id
}

resource "aws_route_table_association" "private-rt2" {
  subnet_id      = "subnet-27d06b41" // Private subnet 2
  route_table_id = aws_route_table.private-rt.id
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = "subnet-1fa82c40" // Public subnet
}

resource "aws_eip" "nat" {
  vpc = true
}

resource "aws_efs_file_system" "jenkins_efs" {
  creation_token = "jenkins-efs"
  performance_mode = "generalPurpose" // or "maxIO"
  throughput_mode = "elastic"
}

resource "aws_efs_mount_target" "jenkins_efs_mt_1" {
  file_system_id  = aws_efs_file_system.jenkins_efs.id
  subnet_id       = "subnet-6960e648" // Private subnet
  security_groups = ["sg-0ca22c73e7506a0f0"]
}

resource "aws_efs_access_point" "jenkins_access_point" {
  file_system_id = aws_efs_file_system.jenkins_efs.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/var/jenkins_home"

    creation_info {
      owner_uid    = 1000
      owner_gid    = 1000
      permissions  = "755"
    }
  }
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
  cpu                      = "1500"
  memory                   = "1500"

  container_definitions = jsonencode([
    {
      name      = "jenkins-master"
      image     = "841578821997.dkr.ecr.us-east-1.amazonaws.com/querkydevs-jenkins-terraform:latest"
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
      mountPoints = [
        {
          sourceVolume  = "jenkins-efs"
          containerPath = "/var/jenkins_home"
          readOnly      = false
        }
      ]
    }
  ])
  volume {
    name = "jenkins-efs"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.jenkins_efs.id
      transit_encryption      = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.jenkins_access_point.id
      }
    }
  }
}

resource "aws_ecs_service" "jenkins_master_service" {
  name            = "jenkins-master-service"
  cluster         = aws_ecs_cluster.jenkins_cluster.id
  task_definition = aws_ecs_task_definition.jenkins_master_task.arn
  desired_count   = 1
  launch_type     = "EC2"
  force_new_deployment = true
  
  network_configuration {
    subnets         = ["subnet-6960e648", "subnet-27d06b41"] // Private subnets
    security_groups = ["sg-0ca22c73e7506a0f0", "sg-0bb4647ebf01edb61", "sg-0cd70ecf61463c2e9"]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.jenkins_tg.arn
    container_name   = "jenkins-master"
    container_port   = 8080
  }
}

resource "aws_launch_template" "jenkins_lt" {
  name          = "jenkins-lt"
  image_id      = "ami-04681163a08179f28" // Amazon Linux 2 AMI x86
  instance_type = "t3a.small"             // x86
  
  network_interfaces {
    associate_public_ip_address = false // Use private IP
    subnet_id                   = "subnet-6960e648" // Private subnet
    security_groups             = ["sg-0ca22c73e7506a0f0", "sg-0bb4647ebf01edb61", "sg-0cd70ecf61463c2e9"]
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
  vpc_zone_identifier  = ["subnet-6960e648"] // Private subnet
  force_delete = true

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
  subnets            = ["subnet-1fa82c40", "subnet-eb33fcda", "subnet-6960e648"] // Public subnets & Private
}

resource "aws_lb_target_group" "jenkins_tg" {
  name         = "jenkins-tg"
  port         = 8080
  protocol     = "HTTP"
  vpc_id       = "vpc-1d9f4860"
  target_type  = "ip"
  health_check {
    path                = "/login"
    port                = 8080
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

resource "aws_iam_role_policy" "ecs_instance_role_policy" {
  name   = "ecs_instance_role_policy"
  role   = aws_iam_role.ecs_instance_role.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = aws_iam_role.ecs_instance_role.arn
      }
    ]
  })
}

output "jenkins_url" {
  value       = aws_lb.jenkins_lb.dns_name
  description = "The DNS name of the Jenkins load balancer"
}