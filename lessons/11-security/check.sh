#!/bin/sh
. "$(dirname "$0")/../lib.sh"

echo "11 security hardening"
check "namespace secure exists with enforce=restricted" sh -c \
  '[ "$(kubectl get ns secure -o jsonpath="'{'"{.metadata.labels.pod-security\.kubernetes\.io/enforce}"'}'")" = "restricted" ]'
check "deployment api exists" kubectl get deploy api -n secure
check_eq "api 2/2 ready" "2" kubectl get deploy api -n secure -o jsonpath='{.status.readyReplicas}'
check_eq "api runs non-root" "101" kubectl get deploy api -n secure -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsUser}'
check_eq "api drops all caps" "ALL" kubectl get deploy api -n secure -o jsonpath='{.spec.template.spec.containers[0].securityContext.capabilities.drop[0]}'
check_eq "api ro rootfs" "true" kubectl get deploy api -n secure -o jsonpath='{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}'
check_eq "api no priv esc" "false" kubectl get deploy api -n secure -o jsonpath='{.spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation}'
check "service api exists" kubectl get svc api -n secure
check_eq "api svc targets 8080" "8080" kubectl get svc api -n secure -o jsonpath='{.spec.ports[0].targetPort}'
check_eq "regcred is dockerconfigjson" "kubernetes.io/dockerconfigjson" kubectl get secret regcred -n secure -o jsonpath='{.type}'
check "regcred on default SA" sh -c \
  'kubectl get sa default -n secure -o jsonpath="{.imagePullSecrets[*].name}" | grep -q regcred'
check "sneaky pod rejected at admission" sh -c '! kubectl get pod sneaky -n secure >/dev/null 2>&1'

summary