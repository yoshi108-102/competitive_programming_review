# Phase 6: Bedrock (Claude) Sandbox

Invoke Amazon Bedrock (Claude 3 Haiku) via Lambda, observe CloudWatch metrics.

## Prerequisites

**Enable model access BEFORE deploying.**
Console -> Bedrock -> Model access -> Manage model access -> Enable Claude 3 Haiku.
Wait for "Access granted" status. Without this, InvokeModel returns 403.

## Deploy

```sh
make sandbox-up-phase6
```

## Generate load

```sh
bash terraform/sandboxes/phase6/load.sh
```

load.sh checks model access (exits with error if 403) then invokes Lambda 3 times
with short fixed prompts to minimize token charges.

## Observe

```sh
bash terraform/sandboxes/phase6/watch.sh
```

Or open the CloudWatch dashboard from the URL printed by watch.sh.

## Tear down

```sh
make sandbox-down-phase6
```

S3 and KMS charges accrue until destroyed. Run `sandbox-down` promptly.

## Key resources

| Resource | Purpose |
|---|---|
| Lambda `bedrock-sandbox-invoker` | Wraps Bedrock InvokeModel |
| S3 `bedrock-sandbox-invocation-logs-<account>` | Bedrock invocation log storage |
| KMS `alias/phase6-bedrock` | CMK for S3/CloudWatch/Lambda env encryption |
| CloudWatch dashboard `phase6-bedrock` | InvocationCount, Latency, Tokens, Lambda metrics |
| Log group `/aws/bedrock/invocations` | Bedrock model invocation logs (retention 1d) |

## Caveats

- `aws_bedrock_model_invocation_logging_configuration` is a singleton per account/region.
  If another sandbox already owns it, `apply` will overwrite that configuration.
- If using a cross-region inference profile, set `TF_VAR_model_id` to the profile ARN
  and update `MODEL_ID` in `watch.sh` to match (CloudWatch dimension uses the ARN).
- Bedrock metrics can take 2-5 minutes to appear in CloudWatch after invocation.
