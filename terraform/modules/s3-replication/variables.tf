variable "app_name" { type = string }
variable "account_id" { type = string; description = "AWS account ID — used to ensure globally unique bucket names" }
variable "tags" { type = map(string); default = {} }
