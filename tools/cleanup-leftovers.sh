#!/usr/bin/env bash
# Removes what the stacks and the console leave behind:
#   - every revision of the task definition family fis-demo-task
#   - the CloudWatch log groups used by this project
# Run it after the ECS service is deleted. Usage: bash tools/cleanup-leftovers.sh
set -euo pipefail

FAMILY="fis-demo-task"
LOG_GROUPS=(
  "/ecs/fis-demo"
  "/ecs/fis-demo-task"
  "/aws/codebuild/fis-demo-failover-test"
)

echo "Step 1: deregister the active revisions of ${FAMILY}."
for arn in $(aws ecs list-task-definitions --family-prefix "$FAMILY" --status ACTIVE \
    --query "taskDefinitionArns[]" --output text); do
  [ "$arn" = "None" ] && continue
  aws ecs deregister-task-definition --task-definition "$arn" > /dev/null
  echo "deregistered ${arn}"
done

echo "Step 2: delete the inactive revisions of ${FAMILY}."
inactive=()
for arn in $(aws ecs list-task-definitions --family-prefix "$FAMILY" --status INACTIVE \
    --query "taskDefinitionArns[]" --output text); do
  [ "$arn" = "None" ] && continue
  inactive+=("$arn")
done
while [ "${#inactive[@]}" -gt 0 ]; do
  batch=("${inactive[@]:0:10}")
  aws ecs delete-task-definitions --task-definitions "${batch[@]}" > /dev/null
  echo "deleted ${#batch[@]} revisions"
  inactive=("${inactive[@]:10}")
done

echo "Step 3: delete the CloudWatch log groups."
for lg in "${LOG_GROUPS[@]}"; do
  found="$(aws logs describe-log-groups --log-group-name-prefix "$lg" \
    --query "length(logGroups[?logGroupName=='${lg}'])" --output text)"
  if [ "$found" = "1" ]; then
    aws logs delete-log-group --log-group-name "$lg"
    echo "deleted log group ${lg}"
  else
    echo "log group ${lg} not found, skipping"
  fi
done

echo "Cleanup finished."
