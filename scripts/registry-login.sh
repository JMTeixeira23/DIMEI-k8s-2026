#!/usr/bin/env bash
# scripts/registry-login.sh
# Authenticates Docker to the active cloud registry.
# Dispatches on $CLOUD — adding Azure support requires adding an elif block.
set -euo pipefail

: "${CLOUD:?CLOUD not set — source env.aws}"

case "${CLOUD}" in
  aws)
    : "${AWS_REGION:?}"
    : "${AWS_ACCOUNT_ID:?}"
    REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    echo "🔑 Logging into ECR: ${REGISTRY}"
    aws ecr get-login-password --region "${AWS_REGION}" \
      | docker login --username AWS --password-stdin "${REGISTRY}"
    ;;

  # Future — uncomment when Azure phase begins:
  # azure)
  #   : "${ACR_NAME:?}"
  #   echo "🔑 Logging into ACR: ${ACR_NAME}.azurecr.io"
  #   az acr login --name "${ACR_NAME}"
  #   ;;

  *)
    echo "❌ Unknown CLOUD: ${CLOUD}. Valid values: aws" >&2
    exit 1
    ;;
esac

echo "✅ Registry login successful"
