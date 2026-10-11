#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "04 config and secrets"
check_eq "configmap task-cfg has MODE=prod" "prod" kubectl get cm task-cfg -o jsonpath='{.data.MODE}'
check_contains "configmap task-cfg has nginx.conf" "listen 8080" kubectl get cm task-cfg -o jsonpath='{.data.nginx\.conf}'
check_eq "secret task-secret API_KEY=abc123" "abc123" sh -c "kubectl get secret task-secret -o jsonpath='{.data.API_KEY}' | base64 -d"
check "deployment task-web ready" kubectl rollout status deploy/task-web --timeout=5s
check_eq "MODE env from configMapKeyRef" "task-cfg" kubectl get deploy task-web -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MODE")].valueFrom.configMapKeyRef.name}'
check_eq "API_KEY env from secretKeyRef" "task-secret" kubectl get deploy task-web -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="API_KEY")].valueFrom.secretKeyRef.name}'
check_eq "nginx.conf mounted with subPath" "nginx.conf" kubectl get deploy task-web -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[?(@.mountPath=="/etc/nginx/nginx.conf")].subPath}'
check "config-hash annotation on pod template" sh -c "[ -n \"\$(kubectl get deploy task-web -o jsonpath='{.spec.template.metadata.annotations.config-hash}')\" ]"
check_eq "pod sees MODE=prod" "prod" sh -c "kubectl exec deploy/task-web -- sh -c 'echo \$MODE'"
check_eq "pod sees API_KEY" "abc123" sh -c "kubectl exec deploy/task-web -- sh -c 'echo \$API_KEY'"
check_eq "healthz answers ok on 8080" "ok" kubectl exec deploy/task-web -- wget -qO- localhost:8080/healthz

summary
