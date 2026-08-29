variable "app_name" { type = string; default = "dr-platform" }
variable "environment" { type = string; default = "production" }
variable "vpc_cidr" { type = string; default = "10.0.0.0/16" }
variable "certificate_arn" { type = string; description = "ACM certificate ARN (us-east-1)" }
variable "db_instance_class" { type = string; default = "db.t3.medium" }
variable "db_name" { type = string; default = "appdb" }
variable "db_username" { type = string; default = "appuser" }
variable "db_password" { type = string; sensitive = true }
