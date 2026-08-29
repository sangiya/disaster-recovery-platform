output "zone_id" { value = aws_route53_zone.main.zone_id }
output "name_servers" { value = aws_route53_zone.main.name_servers; description = "Delegate to these at your registrar" }
output "api_endpoint" { value = "https://api.${var.domain_name}" }
output "health_check_id" { value = module.route53_failover.health_check_id }
