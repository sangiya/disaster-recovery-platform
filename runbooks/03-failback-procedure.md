# Failback Procedure

**Trigger:** Primary region (us-east-1) is restored and healthy  
**Prerequisite:** DR region has been serving traffic for at least 1 hour and all data written since failover has been captured in the DR RDS instance.

> ⚠️ **Failback requires a full maintenance window.** Do not attempt during peak hours.

---

## Phase 1 — Verify Primary Region Recovery

```bash
# Verify primary region infrastructure is healthy
aws ec2 describe-availability-zones --region us-east-1 \
  --query 'AvailabilityZones[].State'

# Verify primary RDS can be restored from latest snapshot
aws rds describe-db-snapshots \
  --db-instance-identifier dr-platform-primary \
  --region us-east-1 \
  --query 'DBSnapshots[0].{ID:DBSnapshotIdentifier,Status:Status,Time:SnapshotCreateTime}' \
  --output table
```

---

## Phase 2 — Sync Data from DR Back to Primary

Since the DR RDS was promoted (replication broken), you must restore primary from the DR instance or a snapshot.

**Option A: Restore primary from DR snapshot (recommended)**
```bash
# Create snapshot of DR (now standalone primary)
aws rds create-db-snapshot \
  --db-instance-identifier dr-platform-dr-replica \
  --db-snapshot-identifier dr-platform-failback-$(date +%Y%m%d%H%M) \
  --region us-west-2

# Copy snapshot to us-east-1
aws rds copy-db-snapshot \
  --source-db-snapshot-identifier <DR_SNAPSHOT_ARN> \
  --target-db-snapshot-identifier dr-platform-failback-copy \
  --source-region us-west-2 \
  --region us-east-1

# Restore primary from copied snapshot
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier dr-platform-primary-restored \
  --db-snapshot-identifier dr-platform-failback-copy \
  --db-instance-class db.t3.medium \
  --multi-az \
  --region us-east-1
```

---

## Phase 3 — Re-enable Primary Infrastructure

```bash
# Scale up primary ECS service
aws ecs update-service \
  --cluster dr-platform-us-east-1 \
  --service dr-platform-service \
  --desired-count 4 \
  --region us-east-1

# Wait for tasks to be healthy
aws ecs wait services-stable \
  --cluster dr-platform-us-east-1 \
  --services dr-platform-service \
  --region us-east-1
```

---

## Phase 4 — Re-enable Primary Route53 Health Check

```bash
# Re-enable the primary health check (was disabled during failover)
aws route53 update-health-check \
  --health-check-id <HEALTH_CHECK_ID> \
  --no-disabled

# Verify primary is now HEALTHY
aws route53 get-health-check-status \
  --health-check-id <HEALTH_CHECK_ID> \
  --query 'CheckerIpRanges'
```

Route53 will automatically shift traffic back to PRIMARY once 3 consecutive health checks pass.

---

## Phase 5 — Re-establish RDS Replication

After failback is confirmed:
1. Promote `dr-platform-primary-restored` (rename it back to `dr-platform-primary`).
2. Re-create the cross-region read replica to us-west-2 via Terraform:
   ```bash
   cd terraform/dr
   terraform apply -var="primary_rds_arn=<NEW_PRIMARY_ARN>"
   ```
3. Monitor `ReplicaLag` until it reaches < 60 seconds before declaring failback complete.

---

## Phase 6 — Scale Down DR Region

```bash
# Return DR ECS to 0 tasks (warm standby state)
aws ecs update-service \
  --cluster dr-platform-us-west-2 \
  --service dr-platform-service \
  --desired-count 0 \
  --region us-west-2
```

---

## Phase 7 — Post-Incident Review

1. Complete incident timeline in ticket.
2. Measure actual RPO: compare last transaction timestamp in primary at failure vs first transaction in DR.
3. Measure actual RTO: time from incident declaration to DR serving traffic.
4. Document lessons learned and update runbook if RTO/RPO were missed.
5. Schedule next DR test within 30 days.
