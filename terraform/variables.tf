variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "ap-southeast-1"
}

variable "instance_type" {
  description = "EC2 instance type with NVIDIA GPUs"
  type        = string
  default     = "g4dn.12xlarge"
  # g4dn.12xlarge = 4x T4 (64GB) - available in ap-southeast-1, TP=4
  # g5.12xlarge   = 4x A10G (96GB) - us-east-1/us-west-2 only, faster with Marlin
  # p4de.24xlarge = 8x A100 (640GB) - overkill for 32B AWQ
}

variable "ami_id" {
  description = "AMI ID - use Deep Learning OSS Nvidia Driver AMI (Ubuntu)"
  type        = string
  default     = "ami-0552b83099ca8fed0"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "desired_capacity" {
  description = "Desired number of instances"
  type        = number
  default     = 1
}

variable "min_instances" {
  description = "Minimum number of instances"
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of instances for scale-out"
  type        = number
  default     = 1
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to access the ALB"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed SSH access to instances"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "monitoring_cidr_blocks" {
  description = "CIDR blocks for Prometheus to scrape metrics from instances"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "enable_deletion_protection" {
  description = "Prevent accidental ALB deletion"
  type        = bool
  default     = false
}

variable "sns_alert_arn" {
  description = "SNS topic ARN for critical alerts (unhealthy hosts, 5xx spikes). Leave empty to disable."
  type        = string
  default     = ""
}
