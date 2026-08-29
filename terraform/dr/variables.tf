variable "app_name" { type = string; default = "dr-platform" }
variable "environment" { type = string; default = "production" }
variable "vpc_cidr" { type = string; default = "10.1.0.0/16" }
variable "certificate_arn" { type = string; description = "ACM certificate ARN (us-west-2)" }
variable "primary_rds_arn" { type = string; description = "Primary RDS instance ARN in us-east-1 — cross-region replica source" }
variable "db_instance_class" { type = string; default = "db.t3.medium" }
