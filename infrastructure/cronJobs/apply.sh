#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Usage & defaults =======================================================
# ./apply.sh --cluster motel-cluster-dev --region us-west-2 \
#            --namespace trafficgen \
#            [--api-token-file ../secrets/api_token.txt] \
#            [--context-name my-ctx] [--dry-run]
#
# If --api-token-file is not provided, the script will read API_TOKEN from env.
# If --context-name is provided, the script will switch to that kube context
# instead of calling `aws eks update-kubeconfig`.

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-}"
NAMESPACE="${NAMESPACE:-trafficgen}"
API_TOKEN_FILE="${API_TOKEN_FILE:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
DRY_RUN="false"

# ===== Helpers ================================================================
die() { echo "❌ $*" >&2; exit 1; }
note(){ echo "👉 $*"; }
ok()  { echo "✅ $*"; }

# ===== Parse args =============================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)        CLUSTER_NAME="$2"; shift 2;;
    --region)         AWS_REGION="$2";   shift 2;;
    --namespace)      NAMESPACE="$2";    shift 2;;
    --api-token-file) API_TOKEN_FILE="$2"; shift 2;;
    --context-name)   KUBE_CONTEXT="$2"; shift 2;;
    --dry-run)        DRY_RUN="true";    shift 1;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'; exit 0;;
    *) die "Unknown argument: $1";;
  esac
done

# ===== Preflight ==============================================================
command -v kubectl >/dev/null 2>&1 || die "kubectl not found"
if [[ -z "${KUBE_CONTEXT}" ]]; then
  command -v aws >/dev/null 2>&1 || die "aws CLI not found"
  [[ -n "${CLUSTER_NAME}" ]] || die "--cluster (or KUBE_CONTEXT) is required"
  [[ -n "${AWS_REGION}"  ]] || die "--region is required when using --cluster"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

note "Working directory: ${SCRIPT_DIR}"

# ===== Select/prepare kube context ===========================================
if [[ -n "${KUBE_CONTEXT}" ]]; then
  note "Using existing kube context: ${KUBE_CONTEXT}"
  kubectl config use-context "${KUBE_CONTEXT}" >/dev/null
else
  note "Updating kubeconfig for cluster '${CLUSTER_NAME}' in region '${AWS_REGION}'..."
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null
fi

ok "Current context: $(kubectl config current-context)"
kubectl cluster-info >/dev/null || die "Cannot reach the cluster with current context."

# ===== Namespace ==============================================================
note "Ensuring namespace '${NAMESPACE}' exists..."
if [[ "${DRY_RUN}" == "true" ]]; then
  kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml
else
  kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
fi
ok "Namespace ready."

# ===== Secret (trafficgen-secret) ============================================
# Secret key required by your CronJobs: API_TOKEN
# Source priority: --api-token-file > env var API_TOKEN
TOKEN_VALUE=""
if [[ -n "${API_TOKEN_FILE}" ]]; then
  [[ -f "${API_TOKEN_FILE}" ]] || die "Token file not found: ${API_TOKEN_FILE}"
  TOKEN_VALUE="$(cat "${API_TOKEN_FILE}")"
elif [[ -n "${API_TOKEN:-}" ]]; then
  TOKEN_VALUE="${API_TOKEN}"
else
  note "No --api-token-file and no API_TOKEN in env. Skipping secret update."
fi

if [[ -n "${TOKEN_VALUE}" ]]; then
  note "Creating/updating secret 'trafficgen-secret' in '${NAMESPACE}'..."
  # Use kubectl with literal so we don't leak in 'env' or shell history beyond this run.
  if [[ "${DRY_RUN}" == "true" ]]; then
    kubectl -n "${NAMESPACE}" create secret generic trafficgen-secret \
      --from-literal=API_TOKEN="${TOKEN_VALUE}" \
      --dry-run=client -o yaml
  else
    kubectl -n "${NAMESPACE}" create secret generic trafficgen-secret \
      --from-literal=API_TOKEN="${TOKEN_VALUE}" \
      --dry-run=client -o yaml | kubectl apply -f -
  fi
  ok "Secret applied."
else
  note "Proceeding without updating 'trafficgen-secret'."
fi

# ===== Apply CronJobs =========================================================
# Supports either:
#  - Kustomize (kustomization.yaml in this folder), or
#  - Plain YAMLs (*.yaml / *.yml)
APPLY_CMD=(kubectl -n "${NAMESPACE}" apply -f -)

if [[ -f "kustomization.yaml" || -f "kustomization.yml" ]]; then
  note "Detected Kustomize config. Building and applying…"
  if [[ "${DRY_RUN}" == "true" ]]; then
    kubectl kustomize . | kubectl -n "${NAMESPACE}" apply --dry-run=client -f -
  else
    kubectl kustomize . | "${APPLY_CMD[@]}"
  fi
else
  note "Applying all YAMLs in $(pwd)…"
  if [[ "${DRY_RUN}" == "true" ]]; then
    kubectl -n "${NAMESPACE}" apply --dry-run=client -f .
  else
    kubectl -n "${NAMESPACE}" apply -f .
  fi
fi
ok "CronJobs applied."

# ===== Status & tips ==========================================================
note "Current CronJobs in '${NAMESPACE}':"
kubectl -n "${NAMESPACE}" get cronjobs

cat <<'HINT'

To manually trigger a CronJob run right now (replace NAME):
  kubectl -n NAMESPACE create job --from=cronjob/NAME "manual-$(date +%s)"

To watch Jobs and Pods:
  kubectl -n NAMESPACE get jobs,pods
  kubectl -n NAMESPACE logs -l job-name=<job-name> --tail=200 -f

To delete all Jobs created by these CronJobs (safe cleanup):
  kubectl -n NAMESPACE delete jobs --all

HINT

ok "Done."
