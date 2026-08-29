# Failover Procedure

**Target RTO:** 15 minutes from incident declaration  
**Trigger:** Primary region (us-east-1) is unavailable or degraded beyond SLO

## Prerequisites

- AWS CLI configured with credentials for both us-east-1 and us-west-2
- `kubectl` or `aws ecs` CLI available
- Access to Route53 console or AWS CLI
- DR environment Terraform state accessible
- On-call runbook executed within Jira/PagerDuty incident ticket

---

## Phase 1 — Declare Incident (0:00)

1. Create incident ticket in PagerDuty.
2. Post to `#incidents` Slack channel:
   ```
   :red_circle: [P1 INCIDENT] Primary region us-east-1 unavailable.
   Runbook: https://github.com/sangiya/disaster-recovery-platform/blob/main/runbooks/02-failover-procedure.md
   ETA to resolution: 15 min (DR failover)
   ```
3. Assign incident commander and comms lead.

---

## Phase 2 — Verify Outage (0:00 – 2:00)

```bash
# Check primary ALB health
aws elbv2 describe-target-health \
  --target-group-arn <PRIMARY_TG_ARN> \
  --region us-east-1

# Check ECS service status
aws ecs describe-services \
  --cluster dr-platform-us-east-1 \
  --services dr-platform-service \
  --region us-east-1

# Check RDS primary status
aws rds describe-db-instances \
  --db-instance-identifier dr-platform-primary \
  --region us-east-1 \
  --query 'DBInstances[0].DBInstanceStatus'
```

If outage is confirmed → proceed to Phase 3.

---

## Phase 3 — Promote RDS Replica (2:00 – 5:00)

```bash
# Promote the DR read replica to standalone primary
# WARNING: This breaks replication — cannot be undone without full restore
aws rds promote-read-replica \
  --db-instance-identifier dr-platform-dr-replica \
  --region us-west-2

# Wait for promotion to complete (typically 1-3 min)
aws rds wait db-instance-available \
  --db-instance-identifier dr-platform-dr-replica \
  --region us-west-2

echo "RDS replica promoted. New endpoint:"
aws rds describe-db-instances \
  --db-instance-identifier dr-platform-dr-replica \
  --region us-west-2 \
  --query 'DBInstances[0].Endpoint.Address'
```

Or run the automated script:
```bash
bash scripts/trigger-failover.sh
```

---

## Phase 4 — Scale Up DR ECS Service (5:00 – 8:00)

```bash
# Scale DR ECS tasks from 0 to active capacity
aws ecs update-service \
  --cluster dr-platform-us-west-2 \
  --service dr-platform-service \
  --desired-count 4 \
  --region us-west-2

# Wait for tasks to reach RUNNING state
aws ecs wait services-stable \
  --cluster dr-platform-us-west-2 \
  --services dr-platform-service \
  --region us-west-2
```

---

## Phase 5 — Update Application Config (8:00 – 10:00)

1. Update the application's `DATABASE_URL` secret in AWS Secrets Manager (us-west-2) to the promoted replica endpoint.
2. Trigger an ECS task force-replacement to pick up the new config:
   ```bash
   aws ecs update-service \
     --cluster dr-platform-us-west-2 \
     --service dr-platform-service \
     --force-new-deployment \
     --region us-west-2
   ```
3. Verify tasks pass `/actuator/health` checks.

---

## Phase 6 — Verify DR Traffic (10:00 – 13:00)

Route53 should automatically fail over once the primary health check fails 3 times. If not, manually update DNS:

```bash
# Check current Route53 health check status
aws route53 get-health-check-status \
  --health-check-id <HEALTH_CHECK_ID>

# Force DNS failover by disabling the primary health check
aws route53 update-health-check \
  --health-check-id <HEALTH_CHECK_ID> \
  --disabled
```

Test the API endpoint:
```bash
curl -sf https://api.example.com/actuator/health | jq .
```

Expected: `{"status": "UP", "region": "us-west-2"}`

---

## Phase 7 — Incident Update (13:00 – 15:00)

1. Post status update to Slack + PagerDuty: DR active, RTO achieved.
2. Record actual RTO and RPO in the incident ticket.
3. Schedule failback planning meeting within 24 hours.
4. DO NOT fail back during business hours without explicit change approval.

---

## Rollback (if failover itself fails)

If DR ECS tasks cannot start or RDS promotion fails:
1. Investigate root cause before proceeding.
2. If DR region is also degraded: escalate to AWS Support, activate manual service degradation page.
3. Do NOT attempt further automation — switch to manual investigation.
