#!/usr/bin/env bash
# Restore traffic to primary region after primary is healthy again.
# Run ONLY during maintenance window with change approval.
set -euo pipefail

APP_NAME="${APP_NAME:-dr-platform}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
DR_REGION="${DR_REGION:-us-west-2}"
HEALTH_CHECK_ID="${HEALTH_CHECK_ID:?Set HEALTH_CHECK_ID env var}"
PRIMARY_ECS_CLUSTER="${PRIMARY_ECS_CLUSTER:-${APP_NAME}-${PRIMARY_REGION}}"
PRIMARY_ECS_SERVICE="${PRIMARY_ECS_SERVICE:-${APP_NAME}-service}"
PRIMARY_TASK_COUNT="${PRIMARY_TASK_COUNT:-4}"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

log "=== FAILBACK TO PRIMARY INITIATED ==="
log "Primary: ${PRIMARY_REGION} | DR: ${DR_REGION}"

# Step 1: Scale up primary ECS
log "Step 1/4: Scaling primary ECS service to ${PRIMARY_TASK_COUNT} tasks..."
aws ecs update-service \
  --cluster "${PRIMARY_ECS_CLUSTER}" \
  --service "${PRIMARY_ECS_SERVICE}" \
  --desired-count "${PRIMARY_TASK_COUNT}" \
  --region "${PRIMARY_REGION}"

aws ecs wait services-stable \
  --cluster "${PRIMARY_ECS_CLUSTER}" \
  --services "${PRIMARY_ECS_SERVICE}" \
  --region "${PRIMARY_REGION}"
log "Primary ECS stable."

# Step 2: Re-enable primary Route53 health check
log "Step 2/4: Re-enabling primary Route53 health check ${HEALTH_CHECK_ID}..."
aws route53 update-health-check \
  --health-check-id "${HEALTH_CHECK_ID}" \
  --no-disabled \
  --region "${PRIMARY_REGION}"
log "Health check re-enabled. Route53 will shift traffic back once 3 checks pass (~90s)."

sleep 100

# Step 3: Verify primary traffic
log "Step 3/4: Verifying primary is receiving traffic..."
PRIMARY_ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names "${APP_NAME}-primary-alb" \
  --region "${PRIMARY_REGION}" \
  --query 'LoadBalancers[0].DNSName' \
  --output text 2>/dev/null || echo "unknown")

if curl -sf --max-time 10 "https://${PRIMARY_ALB_DNS}/actuator/health" -k -o /dev/null; then
  log "Primary ALB health check PASSED."
else
  log "ERROR: Primary ALB health check failed. Aborting failback — traffic remains in DR."
  exit 1
fi

# Step 4: Scale down DR
log "Step 4/4: Scaling down DR ECS service to 0 (warm standby)..."
aws ecs update-service \
  --cluster "${APP_NAME}-${DR_REGION}" \
  --service "${APP_NAME}-service" \
  --desired-count 0 \
  --region "${DR_REGION}"
log "DR ECS scaled to 0."

log "=== FAILBACK COMPLETE ==="
log "Primary region ${PRIMARY_REGION} is now serving traffic."
log "Next: Re-establish RDS cross-region replication via Terraform."
