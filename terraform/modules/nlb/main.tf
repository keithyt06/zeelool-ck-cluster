locals {
  nlb_name = "${var.name_prefix}-nlb"
}

resource "aws_lb" "this" {
  name                             = local.nlb_name
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  security_groups                  = var.security_group_ids
  enable_cross_zone_load_balancing = true

  tags = { Name = local.nlb_name }
}

resource "aws_lb_target_group" "native" {
  name        = "${local.nlb_name}-9000"
  port        = 9000
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "8123"
    path                = "/ping"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group" "http" {
  name        = "${local.nlb_name}-8123"
  port        = 8123
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/ping"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group_attachment" "native" {
  for_each = var.target_instance_ids

  target_group_arn = aws_lb_target_group.native.arn
  target_id        = each.value
  port             = 9000
}

resource "aws_lb_target_group_attachment" "http" {
  for_each = var.target_instance_ids

  target_group_arn = aws_lb_target_group.http.arn
  target_id        = each.value
  port             = 8123
}

resource "aws_lb_listener" "native" {
  load_balancer_arn = aws_lb.this.arn
  port              = 9000
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.native.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8123
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http.arn
  }
}

# No Route53 private zone — clients connect directly to the NLB's AWS-owned
# DNS name (output `dns_name`). If a customer wants a pretty alias, they add
# it in their own DNS system as a CNAME pointing at the NLB DNS.
