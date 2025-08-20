#!/bin/bash
# redeploy-cronjobs.sh
# Cleans up pods & jobs, then redeploys CronJobs with new changes

KUBECONFIG_PATH="../cluster/kubeconfig-api-traffic-generator"
KCTX="api-traffic-generator"
NS="api-traffic"

echo "🚀 Cleaning up old pods in namespace: $NS ..."
kubectl --kubeconfig $KUBECONFIG_PATH --context $KCTX -n $NS delete pod --all --ignore-not-found

echo "🧹 Cleaning up old jobs created by CronJobs ..."
kubectl --kubeconfig $KUBECONFIG_PATH --context $KCTX -n $NS delete jobs --all --ignore-not-found

echo "📦 Re-applying CronJob manifests (make sure YAMLs are in ./cronjobs/)"
kubectl --kubeconfig $KUBECONFIG_PATH --context $KCTX -n $NS apply -f .

echo "✅ CronJobs redeployed with new changes."
echo "👉 To trigger a manual run of a CronJob immediately, use:"
echo "kubectl --kubeconfig $KUBECONFIG_PATH --context $KCTX -n $NS create job <name>-manual-$(date +%s) --from=cronjob/<cronjob-name>"
