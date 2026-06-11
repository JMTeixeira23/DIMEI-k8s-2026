#!/usr/bin/env bash
# scripts/kubeconfig.sh
# Updates ~/.kube/config for the active cloud cluster.
set -euo pipefail

: "${CLOUD:?CLOUD not set — source env.aws}"

case "${CLOUD}" in
  aws)
    : "${AWS_REGION:?}"
    : "${EKS_CLUSTER_NAME:?}"
    echo "🔧 Updating kubeconfig for EKS cluster: ${EKS_CLUSTER_NAME}"
    aws eks update-kubeconfig \
      --region "${AWS_REGION}" \
      --name "${EKS_CLUSTER_NAME}"
    ;;

  # Future:
  # azure)
  #   : "${AKS_CLUSTER_NAME:?}" "${AKS_RESOURCE_GROUP:?}"
  #   echo "🔧 Updating kubeconfig for AKS cluster: ${AKS_CLUSTER_NAME}"
  #   az aks get-credentials \
  #     --resource-group "${AKS_RESOURCE_GROUP}" \
  #     --name "${AKS_CLUSTER_NAME}" \
  #     --overwrite-existing
  #   ;;

  *)
    echo "❌ Unknown CLOUD: ${CLOUD}" >&2
    exit 1
    ;;
esac

echo "✅ Active context: $(kubectl config current-context)"
