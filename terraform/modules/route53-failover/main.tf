# Route53 health check on the primary ALB.
# Route53 stops routing to PRIMARY when 3 consecutive checks fail (90 s).
# This is the main latency driver within the 15-minute RTO target.
resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary_alb_dns
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_check_path
  failure_threshold = 3
  request_interval  = 30

  tags = merge(var.tags, {
    Name = "${var.app_name}-primary-hc"
    Role = "primary"
  })
}

# PRIMARY record: serves all traffic when healthy.
resource "aws_route53_record" "primary" {
  zone_id        = var.zone_id
  name           = var.domain_name
  type           = "A"
  set_identifier = "primary-us-east-1"

  alias {
    name                   = var.primary_alb_dns
    zone_id                = var.primary_alb_zone_id
    evaluate_target_health = true
  }

  failover_routing_policy {
    type = "PRIMARY"
  }

  health_check_id = aws_route53_health_check.primary.id
}

# SECONDARY record: receives traffic ONLY when primary health check fails.
# No health check needed — Route53 always keeps one record active.
resource "aws_route53_record" "secondary" {
  zone_id        = var.zone_id
  name           = var.domain_name
  type           = "A"
  set_identifier = "secondary-us-west-2"

  alias {
    name                   = var.dr_alb_dns
    zone_id                = var.dr_alb_zone_id
    evaluate_target_health = true
  }

  failover_routing_policy {
    type = "SECONDARY"
  }
}
