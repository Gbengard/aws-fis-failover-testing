#!/usr/bin/env bash
# Deletes every object version and delete marker in a bucket, so the stack can delete it.
# Usage: ./scripts/empty-bucket.sh <bucket-name>
set -euo pipefail

BUCKET="${1:?Usage: empty-bucket.sh <bucket-name>}"

for kind in Versions DeleteMarkers; do
  aws s3api list-object-versions --bucket "$BUCKET" \
    --query "${kind}[].[Key,VersionId]" --output text |
  while read -r key version; do
    if [ -z "$key" ] || [ "$key" = "None" ]; then
      continue
    fi
    aws s3api delete-object --bucket "$BUCKET" --key "$key" --version-id "$version" > /dev/null
    echo "deleted ${key} (${version})"
  done
done
echo "Bucket ${BUCKET} is empty."
