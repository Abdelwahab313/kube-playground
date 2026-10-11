#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "02 deployments"
check "deployment api exists" kubectl get deploy api
check_eq "3 replicas desired" "3" kubectl get deploy api -o jsonpath='{.spec.replicas}'
check_eq "3 replicas ready" "3" kubectl get deploy api -o jsonpath='{.status.readyReplicas}'
check_eq "pod label app=api" "api" kubectl get deploy api -o jsonpath='{.spec.template.metadata.labels.app}'
check_contains "image is 1.28 unprivileged" "nginx-unprivileged:1.28" kubectl get deploy api -o jsonpath='{.spec.template.spec.containers[0].image}'
check_eq "readiness probe on 8080" "8080" kubectl get deploy api -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}'
check_eq "readiness period 5s" "5" kubectl get deploy api -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.periodSeconds}'
check_eq "liveness initial delay 10s" "10" kubectl get deploy api -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}'
check_eq "maxSurge 1" "1" kubectl get deploy api -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}'
check_eq "maxUnavailable 0" "0" kubectl get deploy api -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}'
check_eq "cpu request 50m" "50m" kubectl get deploy api -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}'
check_eq "memory request 32Mi" "32Mi" kubectl get deploy api -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}'
check "at least 2 revisions in history" sh -c '[ "$(kubectl rollout history deploy/api | grep -c "^[0-9]")" -ge 2 ]'
check_contains "change-cause annotated" "1.28" kubectl get deploy api -o jsonpath='{.metadata.annotations.kubernetes\.io/change-cause}'

summary
