#!/usr/bin/env bash
# Automated DR failover: promotes RDS replica, scales ECS, disables primary health check.
# Run this ONLY after incident is declared and primary outage confirmed.
set -euo pipefail

APP_NAME="${APP_NAME:-dr-platform}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
DR_REGION="${DR_REGION:-us-west-2}"
DR_RDS_ID="${DR_RDS_ID:-${APP_NAME}-dr-replica}"
DR_ECS_CLUSTER="${DR_ECS_CLUSTER:-${APP_NAME}-${DR_REGION}}"
DR_ECS_SERVICE="${DR_ECS_SERVICE:-${APP_NAME}-service}"
DR_TASK_COUNT="${DR_TASK_COUNT:-4}"
HEALTH_CHECK_ID="${HEALTH_CHECK_ID:?Set HEALTH_CHECK_ID env var}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "=== DISASTER RECOVERY FAILOVER INITIATED ==="
log "Primary: ${PRIMARY_REGION} | DR: ${DR_REGION}"
log "RDS: ${DR_RDS_ID} | ECS: ${DR_ECS_CLUSTER}/${DR_ECS_SERVICE}"

# Step 1: Promote RDS replica
log "Step 1/4: Promoting RDS read replica ${DR_RDS_ID}..."
aws rds promote-read-replica \
  --db-instance-identifier "${DR_RDS_ID}" \
  --region "${DR_REGION}"

log "Waiting for RDS promotion to complete..."
aws rds wait db-instance-available \
  --db-instance-identifier "${DR_RDS_ID}" \
  --region "${DR_REGION}"

NEW_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier "${DR_RDS_ID}" \
  --region "${DR_REGION}" \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)
log "RDS promoted. New endpoint: ${NEW_ENDPOINT}"

# Step 2: Scale up DR ECS service
log "Step 2/4: Scaling DR ECS service to ${DR_TASK_COUNT} tasks..."
aws ecs update-service \
  --cluster "${DR_ECS_CLUSTER}" \
  --service "${DR_ECS_SERVICE}" \
  --desired-count "${DR_TASK_COUNT}" \
  --region "${DR_REGION}"

log "Waiting for ECS tasks to stabilise..."
aws ecs wait services-stable \
  --cluster "${DR_ECS_CLUSTER}" \
  --services "${DR_ECS_SERVICE}" \
  --region "${DR_REGION}"
log "ECS service stable with ${DR_TASK_COUNT} tasks."

# Step 3: Disable primary health check to force Route53 failover immediately
log "Step 3/4: Disabling primary Route53 health check ${HEALTH_CHECK_ID}..."
aws route53 update-health-check \
  --health-check-id "${HEALTH_CHECK_ID}" \
  --disabled \
  --region "${PRIMARY_REGION}"
log "Health check disabled. DNS will failover within 60-90 seconds."

# Step 4: Verify DR API is reachable (via DR ALB DNS, bypassing Route53)
DR_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${APP_NAME}-dr-alb" \
  --region "${DR_REGION}" \
  --query 'LoadBalancers[0].DNSName' \
  --output text 2>/dev/null || echo "unknown")

log "Step 4/4: Verifying DR ALB health at ${DR_ALB_DNS}..."
if curl -sf --max-time 10 "https://${DR_ALB_DNS}/actuator/health" -k -o /dev/null; then
  log "DR ALB health check PASSED."
else
  log "WARNING: DR ALB health check failed. Investigate before confirming failover."
  exit 1
fi

log "=== FAILOVER COMPLETE ==="
log "RTO clock: check incident ticket for elapsed time."
log "Next step: Update DATABASE_URL in DR Secrets Manager to ${NEW_ENDPOINT}"
log "Post #incidents: DR failover complete. Traffic routing to ${DR_REGION}."
