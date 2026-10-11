#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "03 services and networking"
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

check "deployment httpbin exists" kubectl get deploy httpbin
check_eq "2 replicas ready" "2" kubectl get deploy httpbin -o jsonpath='{.status.readyReplicas}'
check_eq "service httpbin is ClusterIP" "ClusterIP" kubectl get svc httpbin -o jsonpath='{.spec.type}'
check_eq "service port 8080" "8080" kubectl get svc httpbin -o jsonpath='{.spec.ports[0].port}'
check_eq "service targetPort 8080" "8080" kubectl get svc httpbin -o jsonpath='{.spec.ports[0].targetPort}'
check "service has 2 endpoints" sh -c '[ "$(kubectl get endpointslices -l kubernetes.io/service-name=httpbin -o jsonpath="{.items[*].endpoints[*].addresses[0]}" | wc -w)" -eq 2 ]'
check_contains "reachable by DNS name from a pod" '"url"' \
  kubectl run check-svc --image=busybox:1.36 --restart=Never --rm -i --quiet --timeout=90s -- wget -qO- --timeout=5 http://httpbin:8080/get
check "ingress-nginx controller running" kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5s
check_eq "ingress class nginx" "nginx" kubectl get ingress httpbin -o jsonpath='{.spec.ingressClassName}'
check_eq "ingress host httpbin.local" "httpbin.local" kubectl get ingress httpbin -o jsonpath='{.spec.rules[0].host}'
check_contains "ingress routes to httpbin from the mac" '"url"' curl -s -m 5 -H "Host: httpbin.local" "http://$NODE_IP/get"

summary
