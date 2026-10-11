#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "00 setup"
check "kubectl installed" command -v kubectl
check "helm installed" command -v helm
check "k9s installed" command -v k9s
check "kubeconfig present" test -f "$KUBECONFIG"
check_eq "node Ready" "True" kubectl get node -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'
check "default storage class exists" sh -c \
  "kubectl get storageclass -o jsonpath='{range .items[*]}{.metadata.name}:{.metadata.annotations.storageclass\\.kubernetes\\.io/is-default-class}{\"\\n\"}{end}' | grep -q ':true'"
check "metrics server answers" kubectl top node
dns_ip=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
check_contains "in-cluster DNS resolves" "$dns_ip" \
  kubectl run check-dns --image=busybox:1.36 --restart=Never --rm -i --quiet --timeout=120s -- nslookup kubernetes.default.svc.cluster.local

summary
