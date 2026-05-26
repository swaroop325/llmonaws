terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- VPC & Networking ---

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  }
}

# --- Security Groups ---

resource "aws_security_group" "alb" {
  name_prefix = "vllm-alb-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vllm-alb-sg" }
}

resource "aws_security_group" "instance" {
  name_prefix = "vllm-instance-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # Allow Prometheus scraping from monitoring instance
  ingress {
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    cidr_blocks     = var.monitoring_cidr_blocks
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "vllm-instance-sg" }
}

# --- ALB ---

resource "aws_lb" "vllm" {
  name               = "vllm-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids

  enable_cross_zone_load_balancing = true
  idle_timeout                     = 300
  enable_deletion_protection       = var.enable_deletion_protection

  tags = { Name = "vllm-alb" }
}

resource "aws_lb_target_group" "vllm" {
  name     = "vllm-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    port                = "8000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 10
    interval            = 30
  }

  deregistration_delay = 120

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 600
    enabled         = true
  }

  target_group_health {
    unhealthy_state_routing {
      minimum_healthy_targets_count = 1
    }
  }

  tags = { Name = "vllm-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.vllm.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.vllm.arn
  }
}

# --- Launch Template ---

resource "aws_launch_template" "vllm" {
  name_prefix   = "vllm-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.instance.id]
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      iops                  = 6000
      throughput            = 400
      delete_on_termination = true
      encrypted             = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = base64encode(templatefile("${path.module}/../user-data.sh", {}))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "vllm-inference"
    }
  }
}

# --- Auto Scaling Group ---

resource "aws_autoscaling_group" "vllm" {
  name                      = "vllm-asg"
  desired_capacity          = var.desired_capacity
  min_size                  = var.min_instances
  max_size                  = var.max_instances
  vpc_zone_identifier       = data.aws_subnets.default.ids
  target_group_arns         = [aws_lb_target_group.vllm.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 900
  default_cooldown          = 180
  termination_policies      = ["OldestInstance"]

  launch_template {
    id      = aws_launch_template.vllm.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 300
    }
  }

  # Spread instances across AZs for redundancy
  tag {
    key                 = "Name"
    value               = "vllm-inference"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Scaling Policies ---

resource "aws_autoscaling_policy" "target_tracking" {
  name                   = "vllm-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.vllm.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.vllm.arn_suffix}/${aws_lb_target_group.vllm.arn_suffix}"
    }
    target_value = 50
  }
}

resource "aws_autoscaling_policy" "scale_out_latency" {
  name                   = "vllm-scale-out-latency"
  autoscaling_group_name = aws_autoscaling_group.vllm.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = 1
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 5
  }

  step_adjustment {
    scaling_adjustment          = 2
    metric_interval_lower_bound = 5
  }
}

resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "vllm-high-target-response-time"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p95"
  threshold           = 10
  alarm_actions       = [aws_autoscaling_policy.scale_out_latency.arn]

  dimensions = {
    TargetGroup  = aws_lb_target_group.vllm.arn_suffix
    LoadBalancer = aws_lb.vllm.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "vllm-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_actions       = var.sns_alert_arn != "" ? [var.sns_alert_arn] : []

  dimensions = {
    TargetGroup  = aws_lb_target_group.vllm.arn_suffix
    LoadBalancer = aws_lb.vllm.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "healthy_host_minimum" {
  alarm_name          = "vllm-healthy-hosts-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Minimum"
  threshold           = var.min_instances
  alarm_actions       = var.sns_alert_arn != "" ? [var.sns_alert_arn] : []

  dimensions = {
    TargetGroup  = aws_lb_target_group.vllm.arn_suffix
    LoadBalancer = aws_lb.vllm.arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "high_5xx" {
  alarm_name          = "vllm-high-5xx-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.sns_alert_arn != "" ? [var.sns_alert_arn] : []

  dimensions = {
    TargetGroup  = aws_lb_target_group.vllm.arn_suffix
    LoadBalancer = aws_lb.vllm.arn_suffix
  }
}

# --- Outputs ---

output "alb_dns_name" {
  value       = aws_lb.vllm.dns_name
  description = "DNS name of the ALB - use this as your API endpoint"
}

output "alb_url" {
  value       = "http://${aws_lb.vllm.dns_name}/v1"
  description = "OpenAI-compatible API base URL"
}

output "asg_name" {
  value       = aws_autoscaling_group.vllm.name
  description = "ASG name for manual scaling commands"
}
