#!/usr/bin/env bash
# Runs the FIS experiment, then checks that the ECS service recovers.
# Exit code 0 = recovered. Any other exit code = the pipeline stage fails.
#
# Required environment variables:
#   TEMPLATE_ID        FIS experiment template ID
#   CLUSTER_NAME       ECS cluster name
#   SERVICE_NAME       ECS service name
#   TARGET_GROUP_ARN   ARN of the ALB target group
# Optional:
#   EXPERIMENT_TIMEOUT  seconds to wait for the experiment to end (default 300)
#   RECOVERY_TIMEOUT    seconds to wait for recovery (default 300)

set -euo pipefail

: "${TEMPLATE_ID:?TEMPLATE_ID is not set}"
: "${CLUSTER_NAME:?CLUSTER_NAME is not set}"
: "${SERVICE_NAME:?SERVICE_NAME is not set}"
: "${TARGET_GROUP_ARN:?TARGET_GROUP_ARN is not set}"

EXPERIMENT_TIMEOUT="${EXPERIMENT_TIMEOUT:-300}"
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-300}"
POLL_SECONDS=10

running_count() {
  aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[0].runningCount' --output text
}

desired_count() {
  aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --query 'services[0].desiredCount' --output text
}

healthy_targets() {
  aws elbv2 describe-target-health \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
    --output text
}

is_recovered() {
  local desired running healthy
  desired="$(desired_count)"
  running="$(running_count)"
  healthy="$(healthy_targets)"
  echo "desired=${desired} running=${running} healthy_targets=${healthy}"
  [ "$running" = "$desired" ] && [ "$healthy" = "$desired" ]
}

case "$TARGET_GROUP_ARN" in
  arn:*:elasticloadbalancing:*:targetgroup/*) ;;
  *)
    echo "TARGET_GROUP_ARN must be the full ARN of the target group, not its name. Got: ${TARGET_GROUP_ARN}" >&2
    exit 1
    ;;
esac

if [ "$(desired_count)" = "None" ]; then
  echo "ECS service ${SERVICE_NAME} was not found in cluster ${CLUSTER_NAME}. Check both names and the Region." >&2
  exit 1
fi

echo "Step 1: check the service is healthy before the test."
if ! is_recovered; then
  echo "The service is not healthy before the test. Stopping here." >&2
  exit 1
fi

echo "Step 2: start the experiment from template ${TEMPLATE_ID}."
EXPERIMENT_ID="$(aws fis start-experiment \
  --experiment-template-id "$TEMPLATE_ID" \
  --query 'experiment.id' --output text)"
echo "Experiment ID: ${EXPERIMENT_ID}"

echo "Step 3: wait for the experiment to end."
elapsed=0
while true; do
  STATUS="$(aws fis get-experiment --id "$EXPERIMENT_ID" \
    --query 'experiment.state.status' --output text)"
  echo "experiment status: ${STATUS}"
  case "$STATUS" in
    completed) break ;;
    stopped|failed|cancelled)
      REASON="$(aws fis get-experiment --id "$EXPERIMENT_ID" \
        --query 'experiment.state.reason' --output text)"
      echo "Experiment ended with status ${STATUS}: ${REASON}" >&2
      exit 1
      ;;
  esac
  if [ "$elapsed" -ge "$EXPERIMENT_TIMEOUT" ]; then
    echo "The experiment did not finish in ${EXPERIMENT_TIMEOUT} seconds." >&2
    exit 1
  fi
  sleep "$POLL_SECONDS"
  elapsed=$((elapsed + POLL_SECONDS))
done

echo "Step 4: wait for the service to recover."
elapsed=0
until is_recovered; do
  if [ "$elapsed" -ge "$RECOVERY_TIMEOUT" ]; then
    echo "The service did not recover in ${RECOVERY_TIMEOUT} seconds." >&2
    exit 1
  fi
  sleep "$POLL_SECONDS"
  elapsed=$((elapsed + POLL_SECONDS))
done

echo "The service recovered. Test passed."
