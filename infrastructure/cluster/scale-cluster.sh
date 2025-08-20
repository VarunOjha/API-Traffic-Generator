#!/usr/bin/env bash
set -euo pipefail

# scale-nodegroup.sh — bump EKS nodegroup capacity and watch nodes join

# Defaults (override via env or flags)
REGION="${REGION:-us-west-2}"
CLUSTER="${CLUSTER:-api-traffic-generator}"
NG="${NG:-}"                 # nodegroup name; if empty we'll auto-detect the first one
MIN_SIZE="${MIN_SIZE:-2}"
MAX_SIZE="${MAX_SIZE:-3}"
DESIRED_SIZE="${DESIRED_SIZE:-4}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-infrastructure/cluster/kubeconfig-api-traffic-generator}"
KUBE_CONTEXT="${KUBE_CONTEXT:-api-traffic-generator}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--region <aws-region>] [--cluster <name>] [--nodegroup <name>]
                        [--min <n>] [--max <n>] [--desired <n>]
                        [--kubeconfig <path>] [--context <name>]

Env overrides: REGION, CLUSTER, NG, MIN_SIZE, MAX_SIZE, DESIRED_SIZE, KUBECONFIG_FILE, KUBE_CONTEXT
EOF
  exit 0
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)     REGION="$2"; shift 2;;
    --cluster)    CLUSTER="$2"; shift 2;;
    --nodegroup)  NG="$2"; shift 2;;
    --min)        MIN_SIZE="$2"; shift 2;;
    --max)        MAX_SIZE="$2"; shift 2;;
    --desired)    DESIRED_SIZE="$2"; shift 2;;
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2;;
    --context)    KUBE_CONTEXT="$2"; shift 2;;
    -h|--help)    usage;;
    *) echo "Unknown arg: $1" >&2; exit 1;;
  esac
done

command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }

echo "Region:  ${REGION}"
echo "Cluster: ${CLUSTER}"

# 1) Find (or confirm) nodegroup
if [[ -z "$NG" ]]; then
  echo "Detecting nodegroup..."
  NG="$(aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION" --query 'nodegroups[0]' --output text)"
  if [[ -z "$NG" || "$NG" == "None" ]]; then
    echo "No nodegroups found. Create one first." >&2
    exit 1
  fi
fi
echo "Nodegroup: $NG"

# 2) Scale it
echo "Scaling to min=$MIN_SIZE max=$MAX_SIZE desired=$DESIRED_SIZE ..."
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NG" \
  --scaling-config minSize="$MIN_SIZE",maxSize="$MAX_SIZE",desiredSize="$DESIRED_SIZE" \
  --region "$REGION" >/dev/null

echo "Update requested. Watching nodes join..."
# 3) Watch nodes
kubectl --kubeconfig "$KUBECONFIG_FILE" --context "$KUBE_CONTEXT" get nodes -w
