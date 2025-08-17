#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------
# Grants/ensures IAM policies for the api-traffic-generator cluster:
#   - ServiceRole: EKS control-plane policies
#   - NodeInstanceRole(s): EKS worker/CNI + ECR ReadOnly + EBS CSI
# Also ensures the aws-ebs-csi-driver addon.
#
# USAGE:
#   ./grant-perms-api-traffic-generator.sh
#   AWS_PROFILE=yourprofile ./grant-perms-api-traffic-generator.sh
#   CLUSTER_NAME=mycluster AWS_REGION=us-east-1 ./grant-perms-api-traffic-generator.sh
# ---------------------------------------------------------------------

# ---------- Defaults (override with env) ----------
CLUSTER_NAME="${CLUSTER_NAME:-api-traffic-generator}"
AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_PROFILE="${AWS_PROFILE:-}"

# Helper that safely injects --profile if provided
awsx() {
  if [[ -n "$AWS_PROFILE" ]]; then
    aws --profile "$AWS_PROFILE" "$@"
  else
    aws "$@"
  fi
}

echo "Cluster name: $CLUSTER_NAME"
echo "Region: $AWS_REGION"
[[ -n "$AWS_PROFILE" ]] && echo "Using profile: $AWS_PROFILE"

# ---------- Partition detection ----------
CALLER_ARN="$(awsx sts get-caller-identity --query Arn --output text)"
PARTITION="$(printf "%s" "$CALLER_ARN" | awk -F: '{print $2}')"
[[ -z "$PARTITION" || "$PARTITION" == "None" ]] && PARTITION="aws"
POLICY_PREFIX="arn:${PARTITION}:iam::aws:policy"

# Policies for ServiceRole (control plane)
read -r -d '' SERVICEROLE_POLICY_ARNS <<EOF || true
${POLICY_PREFIX}/AmazonEKSClusterPolicy
${POLICY_PREFIX}/AmazonEKSVPCResourceController
EOF

# Policies for NodeInstanceRole(s) (workers)
read -r -d '' NODEROLE_POLICY_ARNS <<EOF || true
${POLICY_PREFIX}/AmazonEKSWorkerNodePolicy
${POLICY_PREFIX}/AmazonEKS_CNI_Policy
${POLICY_PREFIX}/AmazonEC2ContainerRegistryReadOnly
${POLICY_PREFIX}/service-role/AmazonEBSCSIDriverPolicy
EOF

# ---------- Discover cluster-related roles ----------
SEARCH_REGEX="${CLUSTER_NAME}"
SERVICE_ROLE_FILTER='^eksctl-.*ServiceRole'
NODE_ROLE_FILTER='NodeInstanceRole'

echo "Discovering IAM roles matching /$SEARCH_REGEX/ ..."
ALL_ROLE_NAMES="$(
  awsx iam list-roles --query 'Roles[].RoleName' --output text \
  | tr '\t' '\n' \
  | grep -E "$SEARCH_REGEX" || true
)"

if [[ -z "$ALL_ROLE_NAMES" ]]; then
  echo "ERROR: No IAM roles matched regex '$SEARCH_REGEX'." >&2
  exit 1
fi

echo "IAM roles for cluster '${CLUSTER_NAME}':"
echo "$ALL_ROLE_NAMES" | sed 's/^/  - /'

# ---------- Attach to ServiceRole ----------
SERVICE_ROLE_NAME="$(echo "$ALL_ROLE_NAMES" | grep -E "$SERVICE_ROLE_FILTER" | sort | head -n 1 || true)"
if [[ -n "$SERVICE_ROLE_NAME" ]]; then
  echo "Using ServiceRole: $SERVICE_ROLE_NAME (partition: $PARTITION)"
  awsx iam get-role --role-name "$SERVICE_ROLE_NAME" >/dev/null

  echo "Attaching policies to ServiceRole: $SERVICE_ROLE_NAME"
  while IFS= read -r ARN; do
    [[ -z "$ARN" ]] && continue
    ATTACHED="$(awsx iam list-attached-role-policies \
      --role-name "$SERVICE_ROLE_NAME" \
      --query "AttachedPolicies[?PolicyArn=='${ARN}'] | length(@)" \
      --output text || echo 0)"
    if [[ "$ATTACHED" == "0" ]]; then
      echo "  -> Attaching $ARN"
      awsx iam attach-role-policy --role-name "$SERVICE_ROLE_NAME" --policy-arn "$ARN"
    else
      echo "  -> Already attached: $ARN"
    fi
  done <<< "$SERVICEROLE_POLICY_ARNS"
else
  echo "WARN: No ServiceRole matched filter '$SERVICE_ROLE_FILTER'. Skipping ServiceRole attachments."
fi

# ---------- Attach to NodeInstanceRole(s) ----------
NODE_ROLE_NAMES="$(echo "$ALL_ROLE_NAMES" | grep -E "$NODE_ROLE_FILTER" || true)"
if [[ -z "$NODE_ROLE_NAMES" ]]; then
  echo "WARN: No NodeInstanceRole matched filter '$NODE_ROLE_FILTER'. Skipping node policy attachments."
else
  echo "NodeInstanceRole(s) detected:"
  echo "$NODE_ROLE_NAMES" | sed 's/^/  - /'
  while IFS= read -r NODE_ROLE; do
    [[ -z "$NODE_ROLE" ]] && continue
    echo "Attaching node policies to: $NODE_ROLE"
    while IFS= read -r ARN; do
      [[ -z "$ARN" ]] && continue
      ATTACHED="$(awsx iam list-attached-role-policies \
        --role-name "$NODE_ROLE" \
        --query "AttachedPolicies[?PolicyArn=='${ARN}'] | length(@)" \
        --output text || echo 0)"
      if [[ "$ATTACHED" == "0" ]]; then
        echo "  -> Attaching $ARN"
        awsx iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn "$ARN"
      else
        echo "  -> Already attached: $ARN"
      fi
    done <<< "$NODEROLE_POLICY_ARNS"
  done <<< "$NODE_ROLE_NAMES"
fi

# ---------- EBS CSI addon ----------
echo "Ensuring aws-ebs-csi-driver addon on cluster '${CLUSTER_NAME}' in ${AWS_REGION}..."
if awsx eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Addon exists; updating with OVERWRITE..."
  awsx eks update-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --region "$AWS_REGION" --resolve-conflicts OVERWRITE
else
  echo "Creating addon..."
  awsx eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --region "$AWS_REGION" --resolve-conflicts OVERWRITE
fi

echo "✅ Done for cluster '${CLUSTER_NAME}' in region '${AWS_REGION}'."
