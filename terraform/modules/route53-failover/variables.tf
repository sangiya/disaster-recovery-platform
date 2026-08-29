variable "app_name" { type = string }
variable "zone_id" { type = string; description = "Route53 hosted zone ID" }
variable "domain_name" { type = string; description = "FQDN for the failover record (e.g. api.example.com)" }
variable "primary_alb_dns" { type = string; description = "Primary ALB DNS name (us-east-1)" }
variable "primary_alb_zone_id" { type = string; description = "Primary ALB hosted zone ID" }
variable "dr_alb_dns" { type = string; description = "DR ALB DNS name (us-west-2)" }
variable "dr_alb_zone_id" { type = string; description = "DR ALB hosted zone ID" }
variable "health_check_path" { type = string; default = "/actuator/health" }
variable "tags" { type = map(string); default = {} }
