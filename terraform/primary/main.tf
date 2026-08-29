terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    # terraform init \
    #   -backend-config="bucket=mycompany-tf-state" \
    #   -backend-config="key=dr-platform/primary/terraform.tfstate" \
    #   -backend-config="region=us-east-1"
  }
}

provider "aws" { region = "us-east-1" }
# DR provider needed by s3-replication module
provider "aws" {
  alias  = "dr"
  region = "us-west-2"
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    Application = var.app_name
    Environment = var.environment
    Region      = "us-east-1"
    Role        = "primary"
    ManagedBy   = "terraform"
  }
}

# ── Networking ──────────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" { state = "available" }
locals { azs = slice(data.aws_availability_zones.available.names, 0, 2) }

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${var.app_name}-primary-vpc" })
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${var.app_name}-primary-public-${local.azs[count.index]}" })
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone = local.azs[count.index]
  tags              = merge(local.tags, { Name = "${var.app_name}-primary-private-${local.azs[count.index]}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.app_name}-primary-igw" })
}

resource "aws_eip" "nat" {
  count  = 1
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.app_name}-primary-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
  tags          = merge(local.tags, { Name = "${var.app_name}-primary-nat" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; gateway_id = aws_internet_gateway.main.id }
  tags = merge(local.tags, { Name = "${var.app_name}-primary-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route { cidr_block = "0.0.0.0/0"; nat_gateway_id = aws_nat_gateway.main.id }
  tags = merge(local.tags, { Name = "${var.app_name}-primary-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── ALB ────────────────────────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name   = "${var.app_name}-primary-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  ingress { from_port = 80; to_port = 80; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"] }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = merge(local.tags, { Name = "${var.app_name}-primary-alb-sg" })
}

resource "aws_lb" "main" {
  name               = "${var.app_name}-primary-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  tags               = merge(local.tags, { Name = "${var.app_name}-primary-alb" })
}

resource "aws_lb_target_group" "main" {
  name        = "${var.app_name}-primary-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"
  health_check { path = "/actuator/health"; healthy_threshold = 3; unhealthy_threshold = 3; interval = 30 }
  tags = merge(local.tags, { Name = "${var.app_name}-primary-tg" })
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  default_action { type = "forward"; target_group_arn = aws_lb_target_group.main.arn }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action { type = "redirect"; redirect { port = "443"; protocol = "HTTPS"; status_code = "HTTP_301" } }
}

# ── RDS Primary ────────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "main" {
  name       = "${var.app_name}-primary-db-subnet"
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

resource "aws_security_group" "rds" {
  name   = "${var.app_name}-primary-rds-sg"
  vpc_id = aws_vpc.main.id
  ingress { from_port = 5432; to_port = 5432; protocol = "tcp"; security_groups = [aws_security_group.alb.id] }
  egress { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"] }
  tags = merge(local.tags, { Name = "${var.app_name}-primary-rds-sg" })
}

resource "aws_db_instance" "primary" {
  identifier             = "${var.app_name}-primary"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = 100
  storage_type           = "gp3"
  storage_encrypted      = true
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = true
  backup_retention_period           = 7
  backup_window                     = "03:00-04:00"
  maintenance_window                = "sun:04:00-sun:05:00"
  skip_final_snapshot               = false
  final_snapshot_identifier         = "${var.app_name}-primary-final"
  deletion_protection               = false
  enabled_cloudwatch_logs_exports   = ["postgresql", "upgrade"]
  performance_insights_enabled      = true
  performance_insights_retention_period = 7
  tags = merge(local.tags, { Name = "${var.app_name}-primary-rds" })
}

# ── S3 Cross-Region Replication ────────────────────────────────────────────────

module "s3_replication" {
  source     = "../modules/s3-replication"
  app_name   = var.app_name
  account_id = data.aws_caller_identity.current.account_id
  tags       = local.tags

  providers = {
    aws    = aws
    aws.dr = aws.dr
  }
}
