#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# destroy.sh — Fully delete an EKS cluster & leftovers (POSIX-friendly)
# - No 'readarray' or 'mapfile'; only simple while-read loops
# - Works even if the cluster and/or kubeconfig/context are gone
# - Cleans up ELBv2/ELB, Target Groups, ENIs, SGs, EBS (opt-in), CW logs, CFN stacks, OIDC
# ------------------------------------------------------------------------------

: "${AWS_REGION:=us-west-2}"
: "${CLUSTER_NAME:=api-traffic-generator}"
: "${KUBE_CONTEXT:=${CLUSTER_NAME}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${SCRIPT_DIR}/kubeconfig-${CLUSTER_NAME}}"

CONFIRM="true"
NUKE_EBS_RETAINED="false"
NUKE_LOG_GROUPS="true"
DELETE_KUBECONFIG_FILE="true"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
say()  { printf "\n🧹 %s\n" "$*"; }
warn() { printf "\n⚠️  %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
note() { printf "   • %s\n" "$*"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
  --region <aws-region>    (default: ${AWS_REGION})
  --cluster <name>         (default: ${CLUSTER_NAME})
  --kubeconfig <path>      (default: ${KUBECONFIG_FILE})
  --context <alias>        (default: ${KUBE_CONTEXT})
  --yes                    Skip confirmation
  --nuke-ebs-retained      Delete 'available' EBS volumes tagged to the cluster
  --keep-logs              Keep CloudWatch logs
  --keep-kubeconfig        Keep kubeconfig file
EOF
}

# --------- Args
while [ $# -gt 0 ]; do
  case "$1" in
    --region) AWS_REGION="$2"; shift 2;;
    --cluster) CLUSTER_NAME="$2"; shift 2;;
    --kubeconfig) KUBECONFIG_FILE="$2"; shift 2;;
    --context) KUBE_CONTEXT="$2"; shift 2;;
    --yes) CONFIRM="false"; shift;;
    --nuke-ebs-retained) NUKE_EBS_RETAINED="true"; shift;;
    --keep-logs) NUKE_LOG_GROUPS="false"; shift;;
    --keep-kubeconfig) DELETE_KUBECONFIG_FILE="false"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

need aws; need eksctl; need kubectl; need jq

echo "👉 AWS_REGION=${AWS_REGION}"
echo "👉 CLUSTER_NAME=${CLUSTER_NAME}"
echo "👉 KUBECONFIG_FILE=${KUBECONFIG_FILE} (may be missing)"
echo "👉 KUBE_CONTEXT=${KUBE_CONTEXT}"
echo "👉 NUKE_EBS_RETAINED=${NUKE_EBS_RETAINED}, NUKE_LOG_GROUPS=${NUKE_LOG_GROUPS}"

if [ "${CONFIRM}" = "true" ]; then
  printf "This will DELETE '%s' and related assets in %s. Continue? (y/N) " "${CLUSTER_NAME}" "${AWS_REGION}"
  read -r yn
  case "$yn" in y|Y|yes|YES) ;; *) echo "Aborted."; exit 1;; esac
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"

# --- Probe cluster (may be deleted already)
CLUSTER_JSON="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --output json 2>/dev/null || true)"
if [ -n "${CLUSTER_JSON}" ]; then
  CLUSTER_EXISTS="true"
  VPC_ID="$(printf "%s" "${CLUSTER_JSON}" | jq -r '.cluster.resourcesVpcConfig.vpcId // empty')"
  OIDC_ISSUER="$(printf "%s" "${CLUSTER_JSON}" | jq -r '.cluster.identity.oidc.issuer // empty')"
else
  CLUSTER_EXISTS="false"
  VPC_ID=""
  OIDC_ISSUER=""
  warn "Cluster not found in EKS API (already deleted). Proceeding with orphan cleanup."
fi

# --- Discover VPC by tag if unknown
if [ -z "${VPC_ID}" ]; then
  say "Trying to discover VPC by tag kubernetes.io/cluster/${CLUSTER_NAME} ..."
  VPC_ID="$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "")"
  [ "${VPC_ID}" = "None" ] && VPC_ID=""
  if [ -n "${VPC_ID}" ]; then ok "Found VPC ${VPC_ID}"; else warn "VPC not found by tag; cleanup will not be VPC-scoped."; fi
fi

# --- Best-effort k8s pre-clean
say "Kubernetes pre-clean (delete LoadBalancer Services & Ingresses)..."
KUBECONFIG_IN_USE="${KUBECONFIG_FILE}"
HAVE_KUBE_ACCESS="false"

if [ -f "${KUBECONFIG_FILE}" ]; then
  if kubectl --kubeconfig "${KUBECONFIG_FILE}" config get-contexts "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    HAVE_KUBE_ACCESS="true"
  fi
elif [ "${CLUSTER_EXISTS}" = "true" ]; then
  KUBECONFIG_IN_USE="/tmp/kubeconfig-${CLUSTER_NAME}"
  aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --alias "${KUBE_CONTEXT}" --kubeconfig "${KUBECONFIG_IN_USE}" >/dev/null 2>&1 || true
  if kubectl --kubeconfig "${KUBECONFIG_IN_USE}" config get-contexts "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    HAVE_KUBE_ACCESS="true"
  fi
fi

if [ "${HAVE_KUBE_ACCESS}" = "true" ]; then
  SVC_LB="$(kubectl --kubeconfig "${KUBECONFIG_IN_USE}" --context "${KUBE_CONTEXT}" get svc -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.spec.type=="LoadBalancer") | "\(.metadata.namespace) \(.metadata.name)"' || true)"
  if [ -n "${SVC_LB}" ]; then
    printf "%s\n" "${SVC_LB}" | while IFS= read -r line; do
      ns="$(printf "%s" "$line" | awk '{print $1}')"
      name="$(printf "%s" "$line" | awk '{print $2}')"
      [ -n "$ns" ] && [ -n "$name" ] || continue
      note "Deleting Service ${ns}/${name}"
      kubectl --kubeconfig "${KUBECONFIG_IN_USE}" --context "${KUBE_CONTEXT}" -n "${ns}" delete svc "${name}" --wait=false || true
    done
  else
    note "No type=LoadBalancer Services found."
  fi
  if kubectl --kubeconfig "${KUBECONFIG_IN_USE}" --context "${KUBE_CONTEXT}" api-resources 2>/dev/null | grep -q "^ingresses"; then
    note "Deleting all Ingresses"
    kubectl --kubeconfig "${KUBECONFIG_IN_USE}" --context "${KUBE_CONTEXT}" delete ingress --all -A --wait=false || true
  fi
else
  note "Skipping k8s pre-clean (no kube access)."
fi

sleep 5

# --- Helpers to delete tagged resources (no arrays, per-resource calls)

delete_tagged_elbv2_and_classic() {
  local scope="$1"
  say "(${scope}) Deleting ELBv2 (ALB/NLB) tagged to cluster..."

  # ELBv2 list
  if [ -n "${VPC_ID}" ]; then
    aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
      --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while IFS= read -r arn; do
        [ -n "$arn" ] || continue
        # tag check per resource (no chunking)
        if aws elbv2 describe-tags --region "${AWS_REGION}" --resource-arns "$arn" --output json 2>/dev/null \
           | jq -e --arg CN "kubernetes.io/cluster/${CLUSTER_NAME}" '.TagDescriptions[].Tags[]?|select(.Key==$CN)' >/dev/null; then
          note "Deleting ELBv2: $arn"
          aws elbv2 delete-load-balancer --region "${AWS_REGION}" --load-balancer-arn "$arn" || true
        fi
      done
  else
    aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
      --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while IFS= read -r arn; do
        [ -n "$arn" ] || continue
        if aws elbv2 describe-tags --region "${AWS_REGION}" --resource-arns "$arn" --output json 2>/dev/null \
           | jq -e --arg CN "kubernetes.io/cluster/${CLUSTER_NAME}" '.TagDescriptions[].Tags[]?|select(.Key==$CN)' >/dev/null; then
          note "Deleting ELBv2: $arn"
          aws elbv2 delete-load-balancer --region "${AWS_REGION}" --load-balancer-arn "$arn" || true
        fi
      done
  fi

  say "(${scope}) Deleting Classic ELB tagged to cluster..."
  if [ -n "${VPC_ID}" ]; then
    aws elb describe-load-balancers --region "${AWS_REGION}" \
      --query "LoadBalancerDescriptions[?VPCId=='${VPC_ID}'].LoadBalancerName" --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while IFS= read -r name; do
        [ -n "$name" ] || continue
        if aws elb describe-tags --region "${AWS_REGION}" --load-balancer-names "$name" --output json 2>/dev/null \
           | jq -e --arg CN "kubernetes.io/cluster/${CLUSTER_NAME}" '.TagDescriptions[].Tags[]?|select(.Key==$CN)' >/dev/null; then
          note "Deleting Classic ELB: $name"
          aws elb delete-load-balancer --region "${AWS_REGION}" --load-balancer-name "$name" || true
        fi
      done
  else
    aws elb describe-load-balancers --region "${AWS_REGION}" \
      --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while IFS= read -r name; do
        [ -n "$name" ] || continue
        if aws elb describe-tags --region "${AWS_REGION}" --load-balancer-names "$name" --output json 2>/dev/null \
           | jq -e --arg CN "kubernetes.io/cluster/${CLUSTER_NAME}" '.TagDescriptions[].Tags[]?|select(.Key==$CN)' >/dev/null; then
          note "Deleting Classic ELB: $name"
          aws elb delete-load-balancer --region "${AWS_REGION}" --load-balancer-name "$name" || true
        fi
      done
  fi
}

delete_tagged_target_groups() {
  say "Deleting Target Groups tagged to cluster..."
  if [ -n "${VPC_ID}" ]; then
    aws elbv2 describe-target-groups --region "${AWS_REGION}" \
      --query "TargetGroups[?VpcId=='${VPC_ID}'].TargetGroupArn" --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while IFS= read -r arn; do
        [ -n "$arn" ] || continue
        if aws elbv2 describe-tags --region "${AWS_REGION}" --resource-arns "$arn" --output json 2>/dev/null \
           | jq -e --arg CN "kubernetes.io/cluster/${CLUSTER_NAME}" '.TagDescriptions[].Tags[]?|select(.Key==$CN)' >/dev/null; then
          note "Deleting Target Group: $arn"
          aws elbv2 delete-target-group --region "${AWS_REGION}" --target-group-arn "$arn" || true
        fi
      done
  else
    aws elbv2 describe-target-groups --region "${AWS_REGION}" \
      --query "TargetGroups[].TargetGroupArn" --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while IFS= read -r arn; do
        [ -n "$arn" ] || continue
        if aws elbv2 describe-tags --region "${AWS_REGION}" --resource-arns "$arn" --output json 2>/dev/null \
           | jq -e --arg CN "kubernetes.io/cluster/${CLUSTER_NAME}" '.TagDescriptions[].Tags[]?|select(.Key==$CN)' >/dev/null; then
          note "Deleting Target Group: $arn"
          aws elbv2 delete-target-group --region "${AWS_REGION}" --target-group-arn "$arn" || true
        fi
      done
  fi
}

# --- Pre-LB cleanup, then cluster deletion (if exists)
delete_tagged_elbv2_and_classic "pre"

if [ "${CLUSTER_EXISTS}" = "true" ]; then
  say "Deleting EKS cluster via eksctl..."
  eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --wait || true
  ok "eksctl delete issued."
else
  note "Skipping eksctl delete (cluster already gone)."
fi

say "Waiting for cluster to be absent from EKS API..."
i=0
while [ $i -lt 30 ]; do
  if ! aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    ok "Cluster absent."
    break
  fi
  i=$((i+1))
  sleep 10
done

# --- Post cleanup
delete_tagged_elbv2_and_classic "post"
delete_tagged_target_groups

if [ -n "${VPC_ID}" ]; then
  say "Deleting ENIs tagged to cluster in VPC ${VPC_ID}..."
  aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
    --query "NetworkInterfaces[?Status=='available'].NetworkInterfaceId" --output text 2>/dev/null \
  | tr '\t' '\n' \
  | while IFS= read -r eni; do
      [ -n "$eni" ] || continue
      note "Deleting ENI $eni"
      aws ec2 delete-network-interface --network-interface-id "$eni" --region "${AWS_REGION}" || true
    done

  say "Deleting Security Groups tagged to cluster..."
  aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" \
    --query "SecurityGroups[].GroupId" --output text 2>/dev/null \
  | tr '\t' '\n' \
  | while IFS= read -r sg; do
      [ -n "$sg" ] || continue
      note "Deleting SG $sg"
      aws ec2 revoke-security-group-egress  --group-id "$sg" --ip-permissions "[]" --region "${AWS_REGION}" >/dev/null 2>&1 || true
      aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "[]" --region "${AWS_REGION}" >/dev/null 2>&1 || true
      aws ec2 delete-security-group --group-id "$sg" --region "${AWS_REGION}" || true
    done
else
  warn "VPC unknown; skipping ENI/SG targeted cleanup."
fi

if [ "${NUKE_EBS_RETAINED}" = "true" ]; then
  say "Deleting 'available' EBS volumes tagged to the cluster..."
  aws ec2 describe-volumes --region "${AWS_REGION}" \
    --filters "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned,shared" "Name=status,Values=available" \
    --query "Volumes[].VolumeId" --output text 2>/dev/null \
  | tr '\t' '\n' \
  | while IFS= read -r vol; do
      [ -n "$vol" ] || continue
      note "Deleting EBS volume $vol"
      aws ec2 delete-volume --volume-id "$vol" --region "${AWS_REGION}" || true
    done
fi

if [ "${NUKE_LOG_GROUPS}" = "true" ]; then
  say "Deleting CloudWatch log groups for cluster..."
  for PREFIX in "/aws/eks/${CLUSTER_NAME}" "/aws/containerinsights/${CLUSTER_NAME}"; do
    aws logs describe-log-groups --region "${AWS_REGION}" \
      --log-group-name-prefix "${PREFIX}" --query "logGroups[].logGroupName" --output text 2>/dev/null \
    | tr '\t' '\n' \
    | while IFS= read -r lg; do
        [ -n "$lg" ] || continue
        note "Deleting log group $lg"
        aws logs delete-log-group --log-group-name "$lg" --region "${AWS_REGION}" || true
      done
  done
fi

# OIDC deletion (only if issuer known)
if [ -n "${OIDC_ISSUER}" ] && [ "${OIDC_ISSUER}" != "None" ]; then
  say "Deleting IAM OIDC provider for cluster..."
  OIDC_PATH="${OIDC_ISSUER#https://}"
  OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PATH}"
  if aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?Arn=='${OIDC_ARN}']" --output text 2>/dev/null | grep -q "${OIDC_ARN}"; then
    note "Deleting OIDC provider ${OIDC_ARN}"
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" || true
  else
    note "OIDC provider not present."
  fi
else
  note "Skipping OIDC deletion (issuer unknown)."
fi

say "Cleaning leftover CloudFormation stacks with prefix eksctl-${CLUSTER_NAME}-* ..."
aws cloudformation list-stacks --region "${AWS_REGION}" \
  --query "StackSummaries[?starts_with(StackName, 'eksctl-${CLUSTER_NAME}-') && StackStatus!='DELETE_COMPLETE'].StackName" \
  --output text 2>/dev/null \
| tr '\t' '\n' \
| while IFS= read -r s; do
    [ -n "$s" ] || continue
    note "Deleting stack $s"
    aws cloudformation delete-stack --stack-name "$s" --region "${AWS_REGION}" || true
  done

# kubeconfig cleanup (best effort)
say "Kubeconfig cleanup..."
if [ -f "${KUBECONFIG_FILE}" ]; then
  if kubectl --kubeconfig "${KUBECONFIG_FILE}" config get-contexts "${KUBE_CONTEXT}" >/dev/null 2>&1; then
    CL_ENTRY="$(kubectl --kubeconfig "${KUBECONFIG_FILE}" config view -o jsonpath="{.contexts[?(@.name=='${KUBE_CONTEXT}')].context.cluster}" || true)"
    US_ENTRY="$(kubectl --kubeconfig "${KUBECONFIG_FILE}" config view -o jsonpath="{.contexts[?(@.name=='${KUBE_CONTEXT}')].context.user}" || true)"
    kubectl --kubeconfig "${KUBECONFIG_FILE}" config delete-context "${KUBE_CONTEXT}" || true
    [ -n "${CL_ENTRY}" ] && kubectl --kubeconfig "${KUBECONFIG_FILE}" config delete-cluster "${CL_ENTRY}" || true
    [ -n "${US_ENTRY}" ] && kubectl --kubeconfig "${KUBECONFIG_FILE}" config unset "users.${US_ENTRY}" || true
  fi
  if [ "${DELETE_KUBECONFIG_FILE}" = "true" ]; then
    note "Deleting kubeconfig file ${KUBECONFIG_FILE}"
    rm -f "${KUBECONFIG_FILE}" || true
  fi
else
  note "No kubeconfig file to clean."
fi

# remove temp kubeconfig if created
if [ "${CLUSTER_EXISTS}" = "true" ] && [ "${KUBECONFIG_IN_USE:-}" = "/tmp/kubeconfig-${CLUSTER_NAME}" ] && [ -f "${KUBECONFIG_IN_USE}" ]; then
  note "Deleting temp kubeconfig ${KUBECONFIG_IN_USE}"
  rm -f "${KUBECONFIG_IN_USE}" || true
fi

ok "Teardown pass complete for '${CLUSTER_NAME}' in ${AWS_REGION}'."
echo "If eksctl VPC stack deletion was blocked by residuals, re-run once more."
