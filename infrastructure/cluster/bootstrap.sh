#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# bootstrap.sh — Create/prepare EKS cluster (NO ECR/IMAGE BUILD HERE)
#   - Renders eksctl spec from cluster.yaml via envsubst
#   - Creates cluster with eksctl (writes to a dedicated kubeconfig file)
#   - Adds a friendly kube context alias
#   - Applies base namespace/configmaps/secret
#
# Expected layout:
#   infrastructure/
#     cluster/
#       bootstrap.sh (this file)
#       cluster.yaml
#       namespace.yaml
#       configmap-motel.yaml
#       configmap-reservation.yaml
#       secret-sample.yaml
# ------------------------------------------------------------------------------

# ---------- Config (override via env or flags) --------------------------------
: "${AWS_REGION:=us-west-2}"
: "${CLUSTER_NAME:=api-traffic-generator}"
: "${KUBE_CONTEXT:=${CLUSTER_NAME}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${SCRIPT_DIR}/kubeconfig-${CLUSTER_NAME}}"

# Manifests in this folder
NS_FILE="${NS_FILE:-${SCRIPT_DIR}/namespace.yaml}"
CM_MOTEL="${CM_MOTEL:-${SCRIPT_DIR}/configmap-motel.yaml}"
CM_RES="${CM_RES:-${SCRIPT_DIR}/configmap-reservation.yaml}"
SECRET_FILE="${SECRET_FILE:-${SCRIPT_DIR}/secret-sample.yaml}"

# ---------- Flags --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)       AWS_REGION="$2"; shift 2;;
    --cluster)      CLUSTER_NAME="$2"; shift 2;;
    --kubeconfig)   KUBECONFIG_FILE="$2"; shift 2;;
    --context)      KUBE_CONTEXT="$2"; shift 2;;
    --ns-file)      NS_FILE="$2"; shift 2;;
    --cm-motel)     CM_MOTEL="$2"; shift 2;;
    --cm-res)       CM_RES="$2"; shift 2;;
    --secret-file)  SECRET_FILE="$2"; shift 2;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [--region us-west-2] [--cluster api-traffic-generator]
                        [--kubeconfig <file>] [--context <alias>]
                        [--ns-file <path>] [--cm-motel <path>] [--cm-res <path>] [--secret-file <path>]
EOF
      exit 0;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

echo "👉 AWS_REGION=${AWS_REGION}"
echo "👉 CLUSTER_NAME=${CLUSTER_NAME}"
echo "👉 KUBECONFIG_FILE=${KUBECONFIG_FILE}"
echo "👉 KUBE_CONTEXT=${KUBE_CONTEXT}"

# ---------- Render eksctl config ----------------------------------------------
export AWS_REGION CLUSTER_NAME
TMP_SPEC="/tmp/cluster.${CLUSTER_NAME}.yaml"
envsubst < "${SCRIPT_DIR}/cluster.yaml" > "${TMP_SPEC}"

# ---------- Create cluster (writes only to KUBECONFIG_FILE) --------------------
eksctl create cluster -f "${TMP_SPEC}" --kubeconfig "${KUBECONFIG_FILE}"

# ---------- Add friendly context alias ----------------------------------------
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --alias "${KUBE_CONTEXT}" \
  --kubeconfig "${KUBECONFIG_FILE}"

# ---------- Apply base namespace & configs ------------------------------------
kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${KUBE_CONTEXT}" apply -f "${NS_FILE}"

# these assume the namespace in NS_FILE is "api-traffic"
kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${KUBE_CONTEXT}" -n api-traffic apply -f "${CM_MOTEL}"
kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${KUBE_CONTEXT}" -n api-traffic apply -f "${CM_RES}"
kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${KUBE_CONTEXT}" -n api-traffic apply -f "${SECRET_FILE}" || true

echo
echo "✅ Cluster '${CLUSTER_NAME}' is ready."
echo "   kubectl --kubeconfig ${KUBECONFIG_FILE} --context ${KUBE_CONTEXT} get nodes"
