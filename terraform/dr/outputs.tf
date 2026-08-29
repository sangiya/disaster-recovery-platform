output "alb_dns_name" { value = aws_lb.main.dns_name }
output "alb_zone_id" { value = aws_lb.main.zone_id }
output "dr_rds_identifier" { value = aws_db_instance.replica.identifier }
output "dr_rds_endpoint" { value = aws_db_instance.replica.endpoint }
