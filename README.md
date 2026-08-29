# disaster-recovery-platform

AWS disaster recovery infrastructure with a 15-minute RTO and 5-minute RPO: Route53 failover routing, RDS cross-region read replica, S3 Cross-Region Replication, and warm-standby ECS in us-west-2.

## Architecture

```
                   Route53 Hosted Zone (api.example.com)
                          │ Failover routing policy
              ┌───────────┴──────────────┐
              ▼ PRIMARY                  ▼ SECONDARY (activates when PRIMARY fails)
         us-east-1                  us-west-2
         ─────────                  ─────────
         ALB (HTTPS)                ALB (HTTPS, pre-warmed)
              │                          │
         ECS Fargate                ECS Fargate
         4 tasks (active)           0 tasks → scales to 4 on failover
              │                          │
         RDS PostgreSQL             RDS Read Replica
         (multi-AZ primary)         (promoted on failover)
              │
         S3 Bucket ──── CRR (async) ───► S3 Replica Bucket
```

**Failover trigger:** Route53 health check on primary ALB fails 3 consecutive times (90 s). Route53 automatically activates the SECONDARY record, sending traffic to DR.

## RTO / RPO

| Objective | Target | Mechanism |
|-----------|--------|-----------|
| RTO | 15 minutes | Route53 auto-failover (90 s) + ECS scale-up (3 min) + task health check (90 s) |
| RPO | 5 minutes | RDS replica lag typically < 1 min; S3 CRR lag < 5 min for small objects |

See `runbooks/01-rto-rpo-targets.md` for full breakdown.

## DR Strategy: Warm Standby

| Component | Primary (us-east-1) | DR (us-west-2) |
|-----------|---------------------|----------------|
| ECS | 4 tasks | 0 tasks (scale up on failover) |
| RDS | Primary (multi-AZ) | Read replica (always running) |
| ALB | Active | Pre-warmed (always provisioned) |
| S3 | Primary bucket | Replica (async CRR) |

## Repository Structure

```
├── terraform/
│   ├── modules/
│   │   ├── s3-replication/     S3 CRR with versioning, lifecycle, IAM replication role
│   │   └── route53-failover/   Health check + PRIMARY/SECONDARY failover records
│   ├── primary/                us-east-1: VPC, ALB, ECS, RDS, S3 source
│   ├── dr/                     us-west-2: VPC, ALB, ECS (0), RDS replica
│   └── global/                 Route53 hosted zone + failover module
├── runbooks/
│   ├── 01-rto-rpo-targets.md   SLO definitions and time budget
│   ├── 02-failover-procedure.md  Step-by-step failover with CLI commands
│   └── 03-failback-procedure.md  Step-by-step failback with CLI commands
└── scripts/
    ├── trigger-failover.sh     Automated failover (RDS promote + ECS scale + DNS)
    ├── trigger-failback.sh     Automated failback (ECS scale + DNS restore + DR scale-down)
    └── dr-readiness-check.sh   Weekly non-destructive readiness validation
```

## Deployment Order

```bash
# 1. Deploy primary region
cd terraform/primary
terraform init -backend-config="bucket=mycompany-tf-state" \
               -backend-config="key=dr-platform/primary/terraform.tfstate" \
               -backend-config="region=us-east-1"
terraform apply

# 2. Deploy DR region (uses primary RDS ARN from step 1)
cd ../dr
terraform init -backend-config="bucket=mycompany-tf-state" \
               -backend-config="key=dr-platform/dr/terraform.tfstate" \
               -backend-config="region=us-east-1"
terraform apply -var="primary_rds_arn=$(cd ../primary && terraform output -raw rds_arn)"

# 3. Deploy global Route53
cd ../global
terraform init -backend-config="bucket=mycompany-tf-state" \
               -backend-config="key=dr-platform/global/terraform.tfstate" \
               -backend-config="region=us-east-1"
terraform apply
```

## Running a DR Test

```bash
# 1. Verify readiness (non-destructive)
export HOSTED_ZONE_ID=<your-zone-id>
bash scripts/dr-readiness-check.sh

# 2. Simulate failover (in test environment only)
export HEALTH_CHECK_ID=<from-terraform-output>
bash scripts/trigger-failover.sh

# 3. Verify DR is serving traffic
curl -sf https://api.example.com/actuator/health | jq .
# Expected: {"status":"UP","region":"us-west-2"}

# 4. Fail back
bash scripts/trigger-failback.sh
```

## CI

GitHub Actions runs `terraform fmt`, `terraform validate`, shell syntax checks, and `tfsec` on every push and pull request.
