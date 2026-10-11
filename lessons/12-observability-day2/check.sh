#!/bin/sh
. "$(dirname "$0")/../lib.sh"

NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
check_ctx=$(kubectl get secret shop-tls -n shop -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d 2>/dev/null)

echo "12 day-2 operations"
check "shop ns exists" kubectl get ns shop >/dev/null 2>&1
check "api deployment ready 1/1" sh -c \
  '[ "$(kubectl get deploy api -n shop -o jsonpath="{.status.readyReplicas}" 2>/dev/null)" = "1" ]'
check "api svc exists" kubectl get svc api -n shop >/dev/null 2>&1
check "ingress shop with TLS secret shop-tls" sh -c \
  '[ "$(kubectl get ingress shop -n shop -o jsonpath="{.spec.tls[0].secretName}" 2>/dev/null)" = "shop-tls" ]'
check "certificate shop-tls READY True" sh -c \
  '[ "$(kubectl get certificate shop-tls -n shop -o jsonpath="{.status.conditions[?(@.type==\"Ready\")].status}" 2>/dev/null)" = "True" ]'
check "tls secret is kubernetes.io/tls" sh -c \
  '[ "$(kubectl get secret shop-tls -n shop -o jsonpath="{.type}" 2>/dev/null)" = "kubernetes.io/tls" ]'
check "httpbin ServiceMonitor targets an unexposed /metrics" sh -c \
  '[ "$(kubectl get servicemonitors httpbin -n metrics-demo -o jsonpath="{.spec.endpoints[0].path}" 2>/dev/null)" = "/metrics" ]'
if [ -n "$NODE_IP" ] && [ -n "$check_ctx" ]; then
  check "https shop.local serves 200 (verified CA)" sh -c \
    'curl -sf --cacert <(printf "%s" "$1") --resolve shop.local:443:'"$NODE_IP"' -o /dev/null https://shop.local/' sh "$check_ctx"
else
  fail "https shop.local serves 200 (verified CA)"
fi

summary