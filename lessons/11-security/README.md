# 11. Security hardening

Goal: stop writing pods an adversary would thank you for. Containers run as root, with every capability, writable filesystem, and no network boundary. Production clusters (and security auditors) enforce the opposite by default. By the end you can read a `securityContext`, make a namespace that **rejects** insecure pods, and pull from a private registry.

## Concept

Kubernetes is not a sandbox. A container is a process on the node kernel; the guards are configuration. Layers, outermost to innermost:

```
API server                        -> RBAC (lesson 06), admission: Pod Security Admission, encryption at rest
Node / kubelet                    -> OS hardening, seccomp/apparmor, kubelet TLS
Container runtime (containerd)    -> runs what you ask, mostly on trust
Pod -> securityContext            -> who it runs as, what it may write, what privileges it keeps
Image                            -> base image, scan for CVEs, pinned/immutable tags
Network                          -> NetworkPolicy, if a CNI enforces it
```

Each layer is independent. A pentester gets in through the weakest one; you do not say "hardened" because one layer is on.

Three objects you have not met:

- **`securityContext`** (pod or container): user/group to run as, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`, Capabilities, `privileged`, `seccompProfile`. It is a *request*; nothing forces you to set it.
- **Pod Security Admission (PSA)**: the gatekeeper. A namespace label makes the API server *reject* pods that violate a policy level. Levels: `privileged` (anything, today's default), `baseline` (prevents the worst: privileged containers, host namespaces/ports, dangerous capabilities), `restricted` (everything baseline plus: no root, no privilege escalation, no writeable rootfs, no arbitrary capabilities). Modes per label: `enforce` (reject), `warn` (allow + warn), `audit` (allow + record in audit log). PSA replaced the old, broken PodSecurityPolicy, removed in 1.25. On EKS/GKE, `restricted` is what managed-`SecurityGroups`/PSS profiles default to.
- **`imagePullSecrets`** (+ Secret type `kubernetes.io/dockerconfigjson`): cluster credentials for a private registry. Without it, `ErrImagePull` / `ImagePullBackOff` with an auth error.

RBAC (06) is the identity boundary, PSA is the workload boundary, NetworkPolicy is the network boundary.

## Walkthrough

### What root grant you today

PREDICT the `CapEff` line before you run it.

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: rooty}
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: [sh, -c, "sleep 3600"]
EOF
kubectl exec rooty -- sh -c 'id; grep CapEff /proc/self/status'
```

Root user, and `CapEff` is a full capability mask (nonzero). That pod is essentially `docker run` as uid 0 with the kitchen sink, on your node.

### Minimal container privileges

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: least}
spec:
  securityContext:
    seccompProfile: {type: RuntimeDefault}
  containers:
  - name: app
    image: busybox:1.36
    command: [sh, -c, "while true; do sleep 5; done"]
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      runAsGroup: 1000
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
EOF
kubectl exec least -- sh -c 'id; grep CapEff /proc/self/status'
kubectl exec least -- touch /tmp/x    # PREDICT
```

### Wait, the app needs to write

`CapEff 0000000000000000`, non-root, and the `touch` fails with `Read-only file system`. Now the app needs scratch space: mount an `emptyDir` at `/tmp` (lesson 05). That is the production pattern: read-only image root plus writable mounts only where the app writes.

### Images that run as root

`runAsNonRoot: true` with an image that runs as root (nginx) is a `CreateContainerConfigError`. Try it:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: asroot}
spec:
  securityContext:
    runAsNonRoot: true
  containers:
  - name: app
    image: nginx:1.27-alpine
EOF
kubectl get pod asroot        # CreateContainerConfigError
kubectl describe pod asroot | grep -A3 Warning
```

Image wants uid 0, policy says no. Use `nginxinc/nginx-unprivileged:1.27-alpine` (runs as 101) or set `runAsUser` explicitly.

### Pod Security Admission, the force multiplier

One label turns your requests into policy.

```sh
kubectl create ns secure
kubectl label ns secure pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted
kubectl get ns secure --show-labels
```

Now violate it. Apply the innocent `rooty` pod but in namespace `secure`:

```sh
kubectl -n secure apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: bad}
spec:
  containers:
  - name: app
    image: nginx:1.27-alpine
EOF
kubectl -n secure get events | grep -i restricted   # see the reason and message
```

Rejected before it reaches any node, with the exact failing standards listed. This is the single highest-leverage hardening move in a real cluster: everything in that namespace must look like the `least` pod or it does not deploy.

Practice a real workload under `restricted`. The unprivileged nginx needs scratch (`/var/cache/nginx`, `/tmp`):

```sh
kubectl -n secure apply -f security.yaml
kubectl -n secure get pods -o wide
kubectl -n secure exec deploy/web -- id        # uid 101, nginx user
```

Read `security.yaml`: `runAsUser/Group: 101`, `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile` and `readOnlyRootFilesystem` with `emptyDir` mounts. This exact pod is what boats pass with `restricted`; commit it as a template.

Now break one field and reapply. Remove `readOnlyRootFilesystem`, or set `runAsUser: 0`. PREDICT: rejected or not? (`restricted` requires non-root and `allowPrivilegeEscalation: false`; a missing RO rootfs is allowed but warned - read the `Warning` event.)

### Private registry: imagePullSecrets

Real images live in a private registry behind auth. Without credentials a pod shows `ErrImagePull` / `ImagePullBackOff` with an auth error.

```sh
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com --docker-username=ci \
  --docker-password='placeholder-token' --namespace secure
kubectl get secret regcred -o jsonpath='{.type}{"\n"}'   # kubernetes.io/dockerconfigjson
kubectl get secret regcred -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d
```

Wire it to a Deployment whose image needs auth. Apply `private.yaml`, then:

```sh
kubectl -n secure apply -f private.yaml
kubectl -n secure get pods -o wide        # ImagePullBackOff - creds are placeholders, registry fake
kubectl -n secure describe pod -l app=private | grep -A2 Events   # Failed to pull image ... auth
```

The point is the mechanics: field `imagePullSecrets` under `spec` of the pod template, secret created by `kubectl create secret docker-registry`, and the kubelet using it during pull. With real creds, that pulls fine. To avoid repeating it on every workload, attach to the namespace's default ServiceAccount:

```sh
kubectl -n secure patch sa default -p '{"imagePullSecrets":[{"name":"regcred"}]}'
```

Every pod using the default SA in that namespace then pulls with those creds. Attach per-workload `serviceAccountName` SAs instead for least privilege.

### NetworkPolicy for real (optional, kind + Cilium)

KubeSolo's CNI does not enforce NetworkPolicy (lesson 03). Enforce it on a kind cluster with Cilium so the YAML you write actually blocks traffic:

```sh
kind create cluster --name netpol
helm install cilium cilium/cilium --namespace kube-system \
  --set ipam.mode=kubernetes --wait
```

Then `kubectl apply` two Deployments (`frontend`, `backend`) and this policy - frontend may call backend on port 8080, nothing else may:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny-all}
spec:
  podSelector: {}        # matches all pods in the namespace
  policyTypes: [Ingress]
  ingress: []
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: allow-frontend-to-backend}
spec:
  podSelector: {matchLabels: {app: backend}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - podSelector: {matchLabels: {app: frontend}}
    ports:
    - {protocol: TCP, port: 8080}
```

`deny-all` proves the default is allow - an empty `ingress: []` turns the namespace to closed. Then the second policy opens one door for one pod. Test with `kubectl exec` from each direction. Clean up: `kind delete cluster --name netpol`.

## Checkpoint

```sh
kubectl -n secure get ns secure --show-labels         # three restricted labels
kubectl -n secure get deploy web                        # 1/1 Ready, uid 101
kubectl -n secure get secret regcred -o jsonpath='{.type}{"\n"}'   # kubernetes.io/dockerconfigjson
kubectl -n secure exec deploy/web -- id                # appuser (101) appgroup (101)
kubectl get pod least -o jsonpath='{.spec.containers[0].securityContext.readOnlyRootFilesystem}{"\n"}'  # true
kubectl auth can-i create pods -n secure --as=system:serviceaccount:secure:default  # should be no
```

## Quiz

1. `securityContext` on a pod vs on a container. Why both levels?
2. A pentester finds your pod runs `CapEff` full mask. Name the one field that fixes it and what it does.
3. PSA `enforce=restricted` rejects a pod. Where was it rejected (control plane, node, runtime)? What does that guarantee?
4. A Deployment in namespace `secure` with `enforce=restricted` rolls fine in dev; in prod the same manifest is rejected. The image is the same. What differs? 
5. `imagePullSecrets` on a pod that already exists - when does the new secret take effect?
6. NetworkPolicy with an empty `ingress: []` + an `allow` policy. What does the empty list do vs no `policyTypes`?
7. Interview: "Describe a production deployment that would survive a container-escape or a misconfigured RBAC grant. How, exactly?"

<details>
<summary>Answers</summary>

1. Pod-level applies to every container (and init container) and holds fields like `fsGroup`, host namespaces, seccomp context. Container-level overrides for one container. You usually set pod-level defaults plus the container's `runAsNonRoot`/capabilities. A CNI chaining guide will floor you on the subtlety, but the interview answer is: pod-level is the shared default, container-level is the per-process exception.
2. `capabilities.drop: [ALL]` on the container (or `seccompProfile: RuntimeDefault` + run unprivileged). It removes every Linux capability from the process capability set so a compromised process cannot perform privileged syscalls even if it escalates within the container's user namespace. Add needed capabilities back via `add` only when the app proves it needs them.
3. In the API server, at admission, before it is stored or scheduled. So the violation never reaches a node. That guarantees policy is uniform - a node that misses the label change on gossip still rejects at the master. It also guarantees a manifest rendered by a buggy script cannot silently drop the security context, because the object is simply not written.

4. The namespace labels. `enforce=restricted` is read per-namespace; dev and prod need the policy namespace. Common failure: prod namespace missing the label so it silently allows; or dev has `warn` not `enforce`. Auditing an EKS cluster where a namespace has `warn` but not `enforce` is a classic finding.
5. On the next pod. Secrets are read by the kubelet at image pull time, not stored in the pod spec. `kubectl rollout restart deploy` makes it effective.
6. Empty `ingress: []` in a policy with `policyTypes: [Ingress]` means "this policy allows no ingress", turning the default-allow into default-deny. No `policyTypes` means the policy only affects the types it lists - dangerous because you can "allow" ingress and leave egress wide open. Always set `policyTypes` explicitly.
7. `restricted` PSA + non-root user + drop ALL capabilities + seccomp, read-only rootfs, no host namespaces/ports - so a compromised process has nothing to escalate to and nothing on the node to reach. RBAC gives the pod's ServiceAccount exactly its own resources, `automountServiceAccountToken: false` when unused. NetworkPolicy closes all by default and opens exactly one path. Image scanning plus immutable tags prevent supply-chain drift. And the things that do break wear a PDB and are observed by lesson 12's stack so someone sees it when it happens. Any three to four of those, named concretely, is a strong answer.
</details>

## Task

Namespace `secure` already has `enforce=restricted`. From memory:

- Deployment `api`, 2 replicas, image `nginxinc/nginx-unprivileged:1.27-alpine`, container port 8080, labels `app: api`
- securityContext that passes `restricted`: `runAsNonRoot: true`, `runAsUser/Group: 101`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true` with the emptyDir mounts the image needs (`/tmp`, `/var/cache/nginx`)
- Service `api` ClusterIP port 80 → target 8080
- Secret `regcred` (type `kubernetes.io/dockerconfigjson`) for a fake registry, attached to the namespace's default ServiceAccount

Verify:

```sh
kubectl -n secure get deploy api -o wide     # 2/2 Ready
kubectl -n secure exec deploy/api -- id      # uid 101
kubectl -n secure apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: sneaky}
spec:
  containers: [{name: bad, image: nginx:1.27-alpine}]
EOF

kubectl -n secure get pod sneaky            # PREDICT: rejected at admission
./check.sh
```

Clean up: `kubectl delete ns secure; kubectl delete pod least rooty asroot`.