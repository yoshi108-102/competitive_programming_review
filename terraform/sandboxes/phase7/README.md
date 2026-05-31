# Phase 7 — EventBridge Sandbox

AWS learning sandbox demonstrating EventBridge custom bus, rules, DLQ, Archive, Scheduler, and EMF custom metrics.

## Architecture

```
put-events (load.sh)
  └─► custom bus (phase7-bus, KMS-encrypted)
       └─► Rule: order.created → Lambda processor
            ├─► Success: EMF metric → CloudWatch Phase7/EventBridge/EventsProcessed
            └─► Failure (retry x2) → DLQ (SQS)

rate(1 minute) [default bus]
  └─► Lambda processor (heartbeat — DESTROY after use!)

EventBridge Scheduler (one-shot at(2099-01-01))
  └─► Lambda processor

Archive: all events on custom bus retained 30 days (replay support)
```

## Quick start

```bash
# 1. Validate (free, no AWS credentials needed)
make sandbox-test-phase7

# 2. Deploy to AWS sandbox account
make sandbox-up-phase7

# 3. Generate load (custom events via put-events)
make sandbox-load-phase7

# 4. Observe metrics (wait ~1-2 min after load)
make sandbox-watch-phase7

# 5. IMPORTANT: destroy when done (rate rule fires every minute)
make sandbox-down-phase7
```

## Key resources

| Resource | Name |
|---|---|
| Custom EventBridge bus | `phase7-bus` |
| Lambda processor | `phase7-processor` |
| DLQ | `phase7-dlq` |
| Event archive | `phase7-archive` |
| Scheduler group | `phase7-group` |
| CloudWatch dashboard | `phase7-dashboard` |

## Observability

- **Lambda Invocations / Errors / Duration** — AWS/Lambda namespace
- **EventsProcessed (EMF)** — Phase7/EventBridge custom namespace
- **FailedInvocations / ThrottledRules** — AWS/Events namespace
- **DLQ messages** — AWS/SQS namespace

## Caveats

- `rate(1 minute)` heartbeat rule fires every minute. Run `make sandbox-down-phase7` immediately after observing.
- KMS key deletion window is 7 days; keys are not destroyed instantly after `terraform destroy`.
- EMF custom metrics take 2-5 minutes to appear in CloudWatch on first invocation.
- The Scheduler `at(2099-01-01T00:00:00)` placeholder will not fire until manually changed.
