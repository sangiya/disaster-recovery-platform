app_name          = "dr-platform"
environment       = "production"
vpc_cidr          = "10.1.0.0/16"
db_instance_class = "db.t3.medium"

# Set from primary stack outputs:
# primary_rds_arn = "arn:aws:rds:us-east-1:123456789012:db:dr-platform-primary"
certificate_arn = "arn:aws:acm:us-west-2:123456789012:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
