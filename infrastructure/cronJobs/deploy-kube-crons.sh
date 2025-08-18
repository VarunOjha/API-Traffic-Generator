kubectl --kubeconfig ../cluster/kubeconfig-api-traffic-generator \
  --context api-traffic-generator \
  -n api-traffic apply -f .