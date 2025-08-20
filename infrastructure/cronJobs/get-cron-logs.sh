#!/bin/bash
# get-cronjob-logs.sh
# Usage: ./get-cronjob-logs.sh <pod-name>

if [ -z "$1" ]; then
  echo "❌ Error: Pod name required"
  echo "Usage: $0 <pod-name>"
  exit 1
fi

POD_NAME=$1

kubectl --kubeconfig ../cluster/kubeconfig-api-traffic-generator \
  --context api-traffic-generator \
  -n api-traffic logs "$POD_NAME" --timestamps
