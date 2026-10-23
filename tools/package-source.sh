#!/usr/bin/env bash
# Builds source.zip from the pipeline-source folder and uploads it to the source bucket.
# Usage: ./tools/package-source.sh <source-bucket-name>
set -euo pipefail

BUCKET="${1:?Usage: package-source.sh <source-bucket-name>}"
SRC_DIR="$(cd "$(dirname "$0")/../pipeline-source" && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

(cd "$SRC_DIR" && zip -r "$TMP_DIR/source.zip" imagedefinitions.json buildspec scripts)

aws s3 cp "$TMP_DIR/source.zip" "s3://${BUCKET}/source.zip"
echo "Uploaded source.zip to s3://${BUCKET}/source.zip"
