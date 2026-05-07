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

# Private hosted zone — create if missing, otherwise adopt via data source.
resource "aws_route53_zone" "private" {
  name = var.hosted_zone_name

  vpc {
    vpc_id = var.vpc_id
  }

  tags = { Name = var.hosted_zone_name }

  lifecycle {
    ignore_changes = [vpc]
  }
}

resource "aws_route53_record" "alias" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "${var.dns_record_name}.${var.hosted_zone_name}"
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
