# RTO / RPO Targets

## Service-Level Objectives

| Metric | Target | Measurement |
|--------|--------|-------------|
| **RTO** (Recovery Time Objective) | **15 minutes** | Time from incident declaration to traffic flowing through DR region |
| **RPO** (Recovery Point Objective) | **5 minutes** | Maximum data loss measured as replication lag at time of incident |
| DR test frequency | Quarterly | Non-destructive failover rehearsal per `02-failover-procedure.md` |
| Health check interval | 30 seconds | Route53 evaluates primary ALB every 30 s |
| DNS failover trigger | 90 seconds | 3 consecutive failures × 30 s = 90 s before SECONDARY serves traffic |
| RDS replica lag target | < 1 minute | Monitored via `ReplicaLag` CloudWatch metric |
| S3 replication lag | < 15 minutes | Standard CRR; enable S3 RTC for guaranteed SLA |

## RTO Budget Breakdown

| Step | Estimated Duration | Cumulative |
|------|--------------------|------------|
| Incident detection + PagerDuty alert | 2 min | 2 min |
| On-call engineer acknowledges | 3 min | 5 min |
| Route53 health check fails (3×30 s) | 1.5 min | 6.5 min |
| DNS TTL propagation (TTL = 60 s) | 1 min | 7.5 min |
| ECS tasks scale up in DR (0 → 4) | 3 min | 10.5 min |
| ECS tasks pass ALB health checks | 1.5 min | 12 min |
| Manual verification + incident update | 3 min | 15 min |

## RPO Budget Breakdown

| Data store | Replication mechanism | Expected lag | Contributes to RPO |
|------------|----------------------|--------------|-------------------|
| PostgreSQL | RDS cross-region read replica | < 1 min typically | Yes |
| Application state (S3) | S3 Cross-Region Replication | < 5 min for objects < 5 MB | Yes |
| In-memory caches (Redis) | Not replicated — accept loss | Up to 30 min | Acceptable (cache rebuild) |
| Kafka topics | Not replicated in this config | N/A | Not applicable |

## DR Strategy: Warm Standby

| Component | Primary (us-east-1) | DR (us-west-2) |
|-----------|---------------------|----------------|
| ECS Fargate | 4 tasks (active) | 0 tasks (scales up on failover) |
| RDS PostgreSQL | Primary (multi-AZ) | Read replica (promote on failover) |
| ALB | Active, serving 100% traffic | Idle (pre-provisioned, ready) |
| S3 | Primary bucket | Replica bucket (async CRR) |
| Route53 | PRIMARY record | SECONDARY record (dormant) |

**Warm standby** keeps all infrastructure running at minimal capacity in DR.
Cost: ~30-40% of primary region cost. RTO impact: 3-5 min for ECS scale-up.

## Monitoring

- `ReplicaLag` CloudWatch metric on DR RDS — alert if > 300 s
- Route53 health check status — alert if UNHEALTHY
- S3 replication latency — monitor via `ReplicationLatency` CloudWatch metric
- ECS service task count — alert if DR tasks > 0 unexpectedly (indicates unplanned failover)
