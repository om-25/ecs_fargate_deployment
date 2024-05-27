
variable "project_name" {
  default = "ecs-fargate-project-omkar"
}

variable "vpc_id" {
  description = "The VPC ID where resources will be deployed"
  type        = string
}


variable "subnet_ids" {
  description = "A list of subnet IDs where resources will be deployed"
  type        = list(string)
}

variable "desired_count" {
  default = 2
}
