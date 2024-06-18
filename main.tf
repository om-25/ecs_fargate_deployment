provider "aws" {
  region = "us-east-1"
}

# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"
}

# IAM Roles
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_cloudwatch_log_group" "log_group" {
  name = "${var.project_name}-ECS-LogGroup"
}


# ECS Task Definition
resource "aws_ecs_task_definition" "main" {
  family                   = "${var.project_name}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.ecs_task_execution.arn
  task_role_arn      = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([{
    name      = "app"
    image     = "nginx:latest"
    cpu       = 256
    memory    = 512
    essential = true
    portMappings = [{
      containerPort = 80
      hostPort      = 80
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.log_group.name
        awslogs-region        = "us-east-1" # Change this to match your region if needed
        awslogs-stream-prefix = "${var.project_name}-awslogs"
      }
    }
  }])
}

# Security Groups
resource "aws_security_group" "lb_sg" {
  name        = "${var.project_name}-lb-sg"
  description = "Security group for load balancer"
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Network Load Balancer
resource "aws_lb" "main" {
  name               = "${var.project_name}-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = var.subnet_ids
}

resource "aws_lb_target_group" "main" {
  name        = "${var.project_name}-tg"
  port        = 80
  protocol    = "TCP"  # Use TCP for NLB
  vpc_id      = var.vpc_id
  target_type = "ip"
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "TCP"  # Use TCP for NLB

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  depends_on = [aws_lb_target_group.main]
}

# ECS Service
resource "aws_ecs_service" "main" {
  name            = "${var.project_name}-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [aws_security_group.lb_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "app"
    container_port   = 80
  }

  depends_on = [aws_ecs_cluster.main, aws_lb_listener.main]
}

# Auto Scaling
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  depends_on = [aws_ecs_service.main]
}

resource "aws_appautoscaling_policy" "cpu_scaling_policy" {
  name               = "${var.project_name}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 50.0

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }

  depends_on = [aws_appautoscaling_target.ecs]
}

resource "aws_appautoscaling_policy" "memory_scaling_policy" {
  name               = "${var.project_name}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 50.0

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }

  depends_on = [aws_appautoscaling_target.ecs]
}

# VPC Link for API Gateway
resource "aws_api_gateway_vpc_link" "example" {
  name        = "${var.project_name}-vpc-link"
  target_arns = [aws_lb.main.arn]

  depends_on = [aws_lb.main]
}

# API Gateway REST API
resource "aws_api_gateway_rest_api" "example" {
  name        = "${var.project_name}-api"
  description = "API for ${var.project_name}"
}

# Root Resource for the API
resource "aws_api_gateway_resource" "root" {
  rest_api_id = aws_api_gateway_rest_api.example.id
  parent_id   = aws_api_gateway_rest_api.example.root_resource_id
  path_part   = "{proxy+}"

  depends_on = [aws_api_gateway_rest_api.example]
}

# POST Method
resource "aws_api_gateway_method" "post_method" {
  rest_api_id   = aws_api_gateway_rest_api.example.id
  resource_id   = aws_api_gateway_resource.root.id
  http_method   = "POST"
  authorization = "NONE"

  depends_on = [aws_api_gateway_resource.root]
}

# POST Integration
resource "aws_api_gateway_integration" "post_integration" {
  rest_api_id             = aws_api_gateway_rest_api.example.id
  resource_id             = aws_api_gateway_resource.root.id
  http_method             = aws_api_gateway_method.post_method.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.main.dns_name}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.example.id

  depends_on = [aws_api_gateway_method.post_method]
}

resource "aws_api_gateway_method_response" "post_method_response" {
  rest_api_id = aws_api_gateway_rest_api.example.id
  resource_id = aws_api_gateway_resource.root.id
  http_method = aws_api_gateway_method.post_method.http_method
  status_code = "200"

  depends_on = [aws_api_gateway_method.post_method]
}

# GET Method
resource "aws_api_gateway_method" "get_method" {
  rest_api_id   = aws_api_gateway_rest_api.example.id
  resource_id   = aws_api_gateway_resource.root.id
  http_method   = "GET"
  authorization = "NONE"

  depends_on = [aws_api_gateway_resource.root]
}

# GET Integration
resource "aws_api_gateway_integration" "get_integration" {
  rest_api_id             = aws_api_gateway_rest_api.example.id
  resource_id             = aws_api_gateway_resource.root.id
  http_method             = aws_api_gateway_method.get_method.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.main.dns_name}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.example.id

  depends_on = [aws_api_gateway_method.get_method]
}

resource "aws_api_gateway_method_response" "get_method_response" {
  rest_api_id = aws_api_gateway_rest_api.example.id
  resource_id = aws_api_gateway_resource.root.id
  http_method = aws_api_gateway_method.get_method.http_method
  status_code = "200"

  depends_on = [aws_api_gateway_method.get_method]
}

# PUT Method
resource "aws_api_gateway_method" "put_method" {
  rest_api_id   = aws_api_gateway_rest_api.example.id
  resource_id   = aws_api_gateway_resource.root.id
  http_method   = "PUT"
  authorization = "NONE"

  depends_on = [aws_api_gateway_resource.root]
}

# PUT Integration
resource "aws_api_gateway_integration" "put_integration" {
  rest_api_id             = aws_api_gateway_rest_api.example.id
  resource_id             = aws_api_gateway_resource.root.id
  http_method             = aws_api_gateway_method.put_method.http_method
  integration_http_method = "ANY"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.main.dns_name}"
  connection_type         = "VPC_LINK"
  connection_id           = aws_api_gateway_vpc_link.example.id

  depends_on = [aws_api_gateway_method.put_method]
}

resource "aws_api_gateway_method_response" "put_method_response" {
  rest_api_id = aws_api_gateway_rest_api.example.id
  resource_id = aws_api_gateway_resource.root.id
  http_method = aws_api_gateway_method.put_method.http_method
  status_code = "200"

  depends_on = [aws_api_gateway_method.put_method]
}

# Deployment
resource "aws_api_gateway_deployment" "example" {
  depends_on = [
    aws_api_gateway_method.post_method,
    aws_api_gateway_integration.post_integration,
    aws_api_gateway_method.get_method,
    aws_api_gateway_integration.get_integration,
    aws_api_gateway_method.put_method,
    aws_api_gateway_integration.put_integration
  ]
  
  rest_api_id = aws_api_gateway_rest_api.example.id
  stage_name  = "newstage2-${terraform.workspace}"  # Use unique stage name
}

# Stage
resource "aws_api_gateway_stage" "example" {
  deployment_id = aws_api_gateway_deployment.example.id
  rest_api_id   = aws_api_gateway_rest_api.example.id
  stage_name    = "newstage2-${terraform.workspace}"  # Use unique stage name

  depends_on = [aws_api_gateway_deployment.example]
}

# Outputs
output "ecs_cluster_id" {
  value = aws_ecs_cluster.main.id
}

output "ecs_service_name" {
  value = aws_ecs_service.main.name
}

output "load_balancer_dns" {
  value = aws_lb.main.dns_name
}

output "api_gateway_url" {
  value = aws_api_gateway_stage.example.invoke_url
}



