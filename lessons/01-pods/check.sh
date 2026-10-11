#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "01 pods"
check "pod task-pod exists" kubectl get pod task-pod
check_eq "phase Running" "Running" kubectl get pod task-pod -o jsonpath='{.status.phase}'
check_eq "label lesson=01" "01" kubectl get pod task-pod -o jsonpath='{.metadata.labels.lesson}'
check_contains "container app" "app" kubectl get pod task-pod -o jsonpath='{.spec.containers[*].name}'
check_contains "container logger" "logger" kubectl get pod task-pod -o jsonpath='{.spec.containers[*].name}'
check_contains "app image nginx" "nginx" kubectl get pod task-pod -o jsonpath='{.spec.containers[?(@.name=="app")].image}'
check_eq "GREETING env on app" "hello" kubectl get pod task-pod -o jsonpath='{.spec.containers[?(@.name=="app")].env[?(@.name=="GREETING")].value}'
check_eq "both containers ready" "true true" kubectl get pod task-pod -o jsonpath='{.status.containerStatuses[*].ready}'
check "logger prints something" sh -c 'kubectl logs task-pod -c logger --tail=3 | grep -q .'

summary
