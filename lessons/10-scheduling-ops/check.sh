#!/bin/sh
. "$(dirname "$0")/../lib.sh"
CTX=kind-multi
k="kubectl --context $CTX"

echo "10 scheduling and node operations"
check_eq "3 nodes" "3" sh -c "$k get nodes --no-headers | wc -l"
check_eq "all nodes Ready / NotReady pairs" "0" sh -c "$k get nodes -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -o 'NotReady' | wc -l"
check "cache deployment exists" sh -c "$k get deploy cache >/dev/null 2>&1"
check_eq "replicas ready 2/2" "2 2" sh -c "$k get deploy cache -o jsonpath='{.spec.replicas} {.status.readyReplicas}'"
check_eq "nodeSelector zone=az1" "az1" sh -c "$k get pods -l app=cache -o jsonpath='{.items[0].spec.nodeSelector.zone}'"
check "replicas on different nodes" sh -c "n=\$($k get pods -l app=cache -o jsonpath='{.items[*].spec.nodeName}'); set -- \$n; [ \$# = 2 ] && [ \"\$1\" != \"\$2\" ]"
check "both pods Ready" sh -c "r=\$($k get pods -l app=cache -o jsonpath='{.items[*].status.containerStatuses[*].ready}'); [ \"\$r\" = \"true true\" ]"
check "tolerates dedicated=cache" sh -c "$k get deploy cache -o jsonpath='{.spec.template.spec.tolerations[*].key}' | grep -q dedicated"
check "topology spread on zone" sh -c "$k get deploy cache -o jsonpath='{.spec.template.spec.topologySpreadConstraints[*].topologyKey}' | grep -q zone"
check "worker2 tainted NoSchedule" sh -c "$k get node kind-multi-worker2 -o jsonpath='{.spec.taints[?(@.key==\"dedicated\")].effect}' | grep -q NoSchedule"

summary