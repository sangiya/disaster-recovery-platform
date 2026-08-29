app_name          = "dr-platform"
environment       = "production"
vpc_cidr          = "10.0.0.0/16"
db_instance_class = "db.t3.medium"
db_name           = "appdb"
db_username       = "appuser"

# Sensitive — supply via TF_VAR_db_password env var or AWS Secrets Manager
# db_password = "..."

# Replace with actual ACM certificate ARN for your domain in us-east-1
certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
