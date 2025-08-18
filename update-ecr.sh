#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_ID="520320208231"
REGION="us-west-2"
REPO="api-traffic-generator"
IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}:latest"

echo "Ensuring ECR repo exists..."
aws ecr describe-repositories --repository-names "${REPO}" --region "${REGION}" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "${REPO}" --region "${REGION}"

echo "Logging in to ECR..."
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "Building local image tagged as ${IMAGE} ..."
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t 520320208231.dkr.ecr.us-west-2.amazonaws.com/api-traffic-generator:latest \
  -t 520320208231.dkr.ecr.us-west-2.amazonaws.com/api-traffic-generator:v1.0.0 \
  --push .

echo "Pushing ${IMAGE} ..."
docker push "${IMAGE}"

echo "✅ Pushed: ${IMAGE}"
