#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "06 namespaces, rbac, resources"
NS=team-a
SA="system:serviceaccount:$NS:deployer"

check "namespace team-a exists" kubectl get ns $NS
check "serviceaccount deployer" kubectl -n $NS get sa deployer
check "role deployer" kubectl -n $NS get role deployer
check "rolebinding deployer" kubectl -n $NS get rolebinding deployer
check_eq "deployer can create deployments" "yes" kubectl auth can-i create deployments --as=$SA -n $NS
check_eq "deployer can patch deployments" "yes" kubectl auth can-i patch deployments --as=$SA -n $NS
check_eq "deployer can list pods" "yes" kubectl auth can-i list pods --as=$SA -n $NS
check_eq "deployer cannot delete pods" "no" kubectl auth can-i delete pods --as=$SA -n $NS
check_eq "deployer cannot read secrets" "no" kubectl auth can-i get secrets --as=$SA -n $NS
check_eq "deployer has nothing in default ns" "no" kubectl auth can-i list pods --as=$SA -n default
check_eq "quota-web 2 ready" "2" kubectl -n $NS get deploy quota-web -o jsonpath='{.status.readyReplicas}'
check_eq "quota-web runs as deployer" "deployer" kubectl -n $NS get deploy quota-web -o jsonpath='{.spec.template.spec.serviceAccountName}'
check_eq "cpu request 50m" "50m" kubectl -n $NS get deploy quota-web -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'
check_eq "memory limit 64Mi" "64Mi" kubectl -n $NS get deploy quota-web -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
check_eq "qos class Burstable" "Burstable" sh -c "kubectl -n $NS get pod -l app=quota-web -o jsonpath='{.items[0].status.qosClass}'"

summary
