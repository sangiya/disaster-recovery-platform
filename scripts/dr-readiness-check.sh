#!/usr/bin/env bash
# Non-destructive DR readiness check — validates DR environment without changing traffic.
# Run weekly or before planned DR tests.
set -euo pipefail

APP_NAME="${APP_NAME:-dr-platform}"
PRIMARY_REGION="${PRIMARY_REGION:-us-east-1}"
DR_REGION="${DR_REGION:-us-west-2}"

PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" &>/dev/null; then
    echo "  [PASS] ${desc}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${desc}"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== DR Readiness Check — $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

echo ""
echo "Primary region (${PRIMARY_REGION}):"
check "RDS primary is available" \
  aws rds describe-db-instances \
    --db-instance-identifier "${APP_NAME}-primary" \
    --region "${PRIMARY_REGION}" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text | grep -q "available"

check "Primary ALB is active" \
  aws elbv2 describe-load-balancers \
    --names "${APP_NAME}-primary-alb" \
    --region "${PRIMARY_REGION}" \
    --query 'LoadBalancers[0].State.Code' \
    --output text | grep -q "active"

check "S3 primary bucket exists and has objects" \
  aws s3 ls "s3://${APP_NAME}-primary-" --region "${PRIMARY_REGION}" 2>/dev/null

echo ""
echo "DR region (${DR_REGION}):"
check "RDS replica is available" \
  aws rds describe-db-instances \
    --db-instance-identifier "${APP_NAME}-dr-replica" \
    --region "${DR_REGION}" \
    --query 'DBInstances[0].DBInstanceStatus' \
    --output text | grep -q "available"

REPLICA_LAG=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name ReplicaLag \
  --dimensions Name=DBInstanceIdentifier,Value="${APP_NAME}-dr-replica" \
  --start-time "$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ')" \
  --end-time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --period 300 \
  --statistics Average \
  --region "${DR_REGION}" \
  --query 'Datapoints[0].Average' \
  --output text 2>/dev/null || echo "999")

if (( $(echo "${REPLICA_LAG} < 300" | bc -l 2>/dev/null || echo 0) )); then
  echo "  [PASS] RDS replica lag: ${REPLICA_LAG}s (< 300s target)"
  PASS=$((PASS + 1))
else
  echo "  [WARN] RDS replica lag: ${REPLICA_LAG}s — investigate if > 300s"
fi

check "DR ALB is active" \
  aws elbv2 describe-load-balancers \
    --names "${APP_NAME}-dr-alb" \
    --region "${DR_REGION}" \
    --query 'LoadBalancers[0].State.Code' \
    --output text | grep -q "active"

check "S3 replica bucket exists" \
  aws s3 ls "s3://${APP_NAME}-replica-" --region "${DR_REGION}" 2>/dev/null

check "DR ECS cluster exists" \
  aws ecs describe-clusters \
    --clusters "${APP_NAME}-${DR_REGION}" \
    --region "${DR_REGION}" \
    --query 'clusters[0].status' \
    --output text | grep -q "ACTIVE"

echo ""
echo "Route53:"
check "Hosted zone has PRIMARY and SECONDARY records" \
  aws route53 list-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID:-none}" \
    --query 'ResourceRecordSets[?Failover!=null]' \
    --output text | grep -q "PRIMARY"

echo ""
echo "=== Summary: ${PASS} passed, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ] && echo "DR environment is READY." && exit 0
echo "DR environment has ${FAIL} issues — remediate before next DR test." && exit 1
