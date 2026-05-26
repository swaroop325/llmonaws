variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type - g5.12xlarge (4x A10G 96GB) for AWQ quantized 32B model with TP=4"
  type        = string
  default     = "g5.12xlarge"
  # g5.12xlarge = 4x A10G (96GB) - recommended, TP=4 for max throughput
  # g5.48xlarge = 8x A10G (192GB) - TP=8, double throughput per instance
  # p4d.24xlarge = 8x A100 (320GB) - highest throughput, lowest latency
}

variable "ami_id" {
  description = "AMI ID - use Amazon Deep Learning AMI or Ubuntu 22.04 with NVIDIA drivers"
  type        = string
  default     = "ami-0123456789abcdef0"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
}

variable "desired_capacity" {
  description = "Desired number of instances (2-4 for 50-200 concurrent users)"
  type        = number
  default     = 3
}

variable "min_instances" {
  description = "Minimum number of instances - at least 2 for redundancy across AZs"
  type        = number
  default     = 2
}

variable "max_instances" {
  description = "Maximum number of instances for scale-out"
  type        = number
  default     = 8
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
