terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    # terraform init \
    #   -backend-config="bucket=mycompany-tf-state" \
    #   -backend-config="key=dr-platform/global/terraform.tfstate" \
    #   -backend-config="region=us-east-1"
  }
}

provider "aws" { region = "us-east-1" }

# Pull ALB outputs from regional state files.
data "terraform_remote_state" "primary" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dr-platform/primary/terraform.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "dr" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "dr-platform/dr/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_route53_zone" "main" {
  name    = var.domain_name
  comment = "Managed by Terraform — disaster-recovery-platform"
  tags    = { Application = var.app_name, ManagedBy = "terraform" }
}

module "route53_failover" {
  source              = "../modules/route53-failover"
  app_name            = var.app_name
  zone_id             = aws_route53_zone.main.zone_id
  domain_name         = "api.${var.domain_name}"
  primary_alb_dns     = data.terraform_remote_state.primary.outputs.alb_dns_name
  primary_alb_zone_id = data.terraform_remote_state.primary.outputs.alb_zone_id
  dr_alb_dns          = data.terraform_remote_state.dr.outputs.alb_dns_name
  dr_alb_zone_id      = data.terraform_remote_state.dr.outputs.alb_zone_id
  tags                = { Application = var.app_name, ManagedBy = "terraform" }
}
