#!/bin/sh
# usage: ./check.sh NN   (01..07)
. "$(dirname "$0")/../lib.sh"

n=${1:?usage: ./check.sh NN}
NS=drill
probe() { kubectl -n $NS run "check-$n-$$" --image=busybox:1.36 --restart=Never --rm -i --quiet --timeout=60s -- "$@"; }

echo "09 drill $n"
case "$n" in
  01)
    check "d01 rolled out" kubectl -n $NS rollout status deploy/d01 --timeout=10s
    check_contains "image is a real nginx tag" "nginx:1.27-alpine" kubectl -n $NS get deploy d01 -o jsonpath='{.spec.template.spec.containers[0].image}'
    ;;
  02)
    check "d02 rolled out" kubectl -n $NS rollout status deploy/d02 --timeout=10s
    check_eq "no restarts on current pod" "0" sh -c "kubectl -n $NS get pod -l app=d02 -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'"
    check "httpd answers on the configured port" sh -c "kubectl -n $NS exec deploy/d02 -- sh -c 'wget -qO- localhost:\$PORT >/dev/null'"
    ;;
  03)
    check "d03 rolled out" kubectl -n $NS rollout status deploy/d03 --timeout=10s
    check_eq "2 replicas ready" "2" kubectl -n $NS get deploy d03 -o jsonpath='{.status.readyReplicas}'
    check "cpu request fits the node" sh -c "[ \"\$(kubectl -n $NS get deploy d03 -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')\" != '8' ]"
    ;;
  04)
    check "service d04 has 2 endpoints" sh -c "[ \"\$(kubectl -n $NS get endpointslices -l kubernetes.io/service-name=d04 -o jsonpath='{.items[*].endpoints[*].addresses[0]}' | wc -w)\" -eq 2 ]"
    check_contains "service d04 serves nginx" "nginx" probe wget -qO- --timeout=5 http://d04/
    ;;
  05)
    check "d05 rolled out" kubectl -n $NS rollout status deploy/d05 --timeout=10s
    check_eq "2 replicas ready" "2" kubectl -n $NS get deploy d05 -o jsonpath='{.status.readyReplicas}'
    check "no restarts on pods" sh -c "[ \"\$(kubectl -n $NS get pod -l app=d05 -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' | tr ' ' '+' | bc)\" -eq 0 ]"
    check_contains "service d05 serves nginx" "nginx" probe wget -qO- --timeout=5 http://d05/
    ;;
  06)
    check "d06 rolled out" kubectl -n $NS rollout status deploy/d06 --timeout=10s
    check_eq "pod sees API_KEY" "abc123" sh -c "kubectl -n $NS exec deploy/d06 -- sh -c 'echo \$API_KEY'"
    check_eq "pod sees LOG_LEVEL" "info" sh -c "kubectl -n $NS exec deploy/d06 -- sh -c 'echo \$LOG_LEVEL'"
    check_contains "custom nginx.conf is live" "d06 ok" kubectl -n $NS exec deploy/d06 -- wget -qO- localhost/
    ;;
  07)
    check "d07 rolled out" kubectl -n $NS rollout status deploy/d07 --timeout=10s
    check_contains "client log shows connected" "connected" sh -c "kubectl -n $NS logs deploy/d07 --tail=3"
    check "no recent failure in client log" sh -c "! kubectl -n $NS logs deploy/d07 --tail=2 | grep -q 'cannot reach'"
    ;;
  *)
    echo "unknown drill $n"; exit 2 ;;
esac

summary
