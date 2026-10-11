#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "05 storage"
check "statefulset cache exists" kubectl get sts cache
check_eq "1 replica ready" "1" kubectl get sts cache -o jsonpath='{.status.readyReplicas}'
check_contains "image redis" "redis" kubectl get sts cache -o jsonpath='{.spec.template.spec.containers[0].image}'
check_contains "appendonly enabled" "appendonly" kubectl get sts cache -o jsonpath='{.spec.template.spec.containers[0].args[*]}'
check_eq "volumeClaimTemplate named data" "data" kubectl get sts cache -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}'
check_eq "claim size 200Mi" "200Mi" kubectl get sts cache -o jsonpath='{.spec.volumeClaimTemplates[0].spec.resources.requests.storage}'
check_eq "mounted at /data" "/data" kubectl get sts cache -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.name=="data")].mountPath}'
check_eq "pvc data-cache-0 bound" "Bound" kubectl get pvc data-cache-0 -o jsonpath='{.status.phase}'
check_eq "service cache is headless" "None" kubectl get svc cache -o jsonpath='{.spec.clusterIP}'
check_eq "key survives pod deletion" "05" kubectl exec cache-0 -- redis-cli get lesson
check "appendonly file exists on the volume" kubectl exec cache-0 -- sh -c 'ls /data/appendonlydir /data/appendonly.aof 2>/dev/null | grep -q .'

summary
