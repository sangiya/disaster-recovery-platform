variable "app_name" { type = string; default = "dr-platform" }
variable "domain_name" { type = string; description = "Root domain (e.g. example.com). api.{domain} gets the failover record." }
variable "state_bucket" { type = string; description = "S3 bucket holding all Terraform state files" }
