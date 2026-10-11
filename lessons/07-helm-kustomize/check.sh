#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "07 helm and kustomize"
check "chart directory shop exists" test -f "$(dirname "$0")/shop/Chart.yaml"
check "chart lints" helm lint "$(dirname "$0")/shop"
check_contains "release shop deployed" "deployed" sh -c "helm list -o json | grep -o '\"name\":\"shop\"[^}]*'"
check "backend deployment from chart" sh -c "kubectl get deploy -l app.kubernetes.io/instance=shop -o name | grep -qi backend"
check "frontend deployment from chart" sh -c "kubectl get deploy -l app.kubernetes.io/instance=shop -o name | grep -qi frontend"
check_eq "frontend.replicas=2 applied" "2" sh -c "kubectl get deploy -l app.kubernetes.io/instance=shop -o json | python3 -c \"import sys,json; d=[i for i in json.load(sys.stdin)['items'] if 'frontend' in i['metadata']['name']][0]; print(d['spec']['replicas'])\""
check_eq "backend default 2 replicas" "2" sh -c "kubectl get deploy -l app.kubernetes.io/instance=shop -o json | python3 -c \"import sys,json; d=[i for i in json.load(sys.stdin)['items'] if 'backend' in i['metadata']['name']][0]; print(d['spec']['replicas'])\""
check_contains "ingress host shop.test" "shop.test" kubectl get ingress -l app.kubernetes.io/instance=shop -o jsonpath='{.items[*].spec.rules[*].host}'
check "kustomize dev overlay renders" kubectl kustomize "$(dirname "$0")/kustomize/overlays/dev"
check "kustomize prod overlay renders" kubectl kustomize "$(dirname "$0")/kustomize/overlays/prod"
check_eq "dev-web has 1 replica" "1" kubectl get deploy dev-web -o jsonpath='{.spec.replicas}'
check_eq "prod-web has 3 replicas" "3" kubectl get deploy prod-web -o jsonpath='{.spec.replicas}'
check_contains "prod-web image patched to 1.28" "1.28" kubectl get deploy prod-web -o jsonpath='{.spec.template.spec.containers[0].image}'

summary
