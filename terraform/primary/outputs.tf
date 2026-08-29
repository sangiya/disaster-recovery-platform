output "alb_dns_name" { value = aws_lb.main.dns_name }
output "alb_zone_id" { value = aws_lb.main.zone_id }
output "rds_arn" { value = aws_db_instance.primary.arn }
output "rds_endpoint" { value = aws_db_instance.primary.endpoint }
output "primary_bucket_name" { value = module.s3_replication.primary_bucket_name }
output "replica_bucket_name" { value = module.s3_replication.replica_bucket_name }
