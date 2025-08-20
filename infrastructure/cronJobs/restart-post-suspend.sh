#!/bin/bash
# suspend-cronjobs.sh
# Suspends all CronJobs in a namespace to stop new jobs/pods from being created

KUBECONFIG_PATH="../cluster/kubeconfig-api-traffic-generator"
KCTX="api-traffic-generator"
NS="api-traffic"

echo "⏸️  Restarting all CronJobs in namespace: $NS ..."

# Get all CronJobs in the namespace
CRONJOBS=$(kubectl --kubeconfig $KUBECONFIG_PATH --context $KCTX -n $NS get cronjobs -o name)

if [ -z "$CRONJOBS" ]; then
  echo "✅ No CronJobs found in namespace $NS"
  exit 0
fi

# Loop and suspend each
for cj in $CRONJOBS; do
  echo "Suspending $cj ..."
  kubectl --kubeconfig $KUBECONFIG_PATH --context $KCTX -n $NS patch $cj -p '{"spec":{"suspend":false}}'
done

echo "🚫 All CronJobs in $NS are now suspended and won’t create new jobs."
