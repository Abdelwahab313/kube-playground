# 06. Namespaces, RBAC, resources

Goal: split one cluster between teams, give a workload the minimum permissions, and understand what requests and limits do at the boundaries.

## Concept

**Namespace**: a name scope and a policy boundary. Most objects live in one (pods, services, configmaps). Some are cluster-wide (nodes, PVs, StorageClasses, Namespaces themselves, ClusterRoles). Same name in two namespaces is two objects. Network is not isolated by default.

**RBAC** answers "can subject X do verb Y on resource Z". Four objects:

| Object | Scope | Says |
|---|---|---|
| Role | namespace | verbs on resources in this namespace |
| ClusterRole | cluster | verbs on resources anywhere, or on cluster-wide resources |
| RoleBinding | namespace | subject gets Role (or ClusterRole) in this namespace |
| ClusterRoleBinding | cluster | subject gets ClusterRole everywhere |

Subjects: users and groups (from your auth provider, not stored in the cluster) and **ServiceAccounts** (stored in the cluster, one per namespace named `default`, the identity of a pod). ECS analogy: task IAM role, except the permissions are on the Kubernetes API, not AWS.

**Resources**:

- `requests`: what the scheduler reserves. Sum of requests on a node cannot exceed capacity. Sets CPU weight under contention.
- `limits`: hard ceiling. CPU over limit is throttled. Memory over limit is `OOMKilled`.
- QoS classes derived from them: `Guaranteed` (requests == limits), `Burstable`, `BestEffort` (none set). Under node memory pressure, BestEffort dies first.

**LimitRange** sets defaults and bounds per container in a namespace. **ResourceQuota** caps the namespace total.

## Walkthrough

### Namespaces

```sh
kubectl create ns team-a
kubectl create ns team-b
kubectl -n team-a create deploy web --image=nginx:1.27-alpine
kubectl -n team-b create deploy web --image=nginx:1.27-alpine
kubectl get deploy -A | grep web
kubectl config set-context --current --namespace=team-a
kubectl get pods          # only team-a now
kubectl config set-context --current --namespace=default
```

Cross-namespace DNS: `web.team-a.svc.cluster.local` works from team-b. Isolation needs NetworkPolicy plus a CNI that enforces it.

### A ServiceAccount that can only read pods

Read `rbac.yaml`: a ServiceAccount `reader`, a Role allowing `get, list, watch` on pods, a RoleBinding, and a pod running as that account.

```sh
kubectl apply -f rbac.yaml
kubectl auth can-i list pods --as=system:serviceaccount:team-a:reader -n team-a
kubectl auth can-i delete pods --as=system:serviceaccount:team-a:reader -n team-a
kubectl auth can-i list pods --as=system:serviceaccount:team-a:reader -n team-b
```

PREDICT each answer before running.

Now from inside the pod, using the mounted token:

```sh
kubectl -n team-a exec reader-pod -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" https://kubernetes.default/api/v1/namespaces/team-a/pods | head -20
  echo; echo "--- delete attempt:"
  curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" -X DELETE https://kubernetes.default/api/v1/namespaces/team-a/pods/reader-pod | head -5'
```

That token is how every in-cluster tool (operators, CI runners, Argo CD) talks to the API. `automountServiceAccountToken: false` on pods that do not need it is a common hardening step.

### Default ServiceAccount can do nothing

```sh
kubectl auth can-i list pods --as=system:serviceaccount:default:default
```

`no`. Every pod has an identity, by default a useless one. Good.

### Requests, limits, OOMKilled

```sh
kubectl apply -f limits.yaml
kubectl get pods -l lesson=06 -w        # ctrl-c after hog shows OOMKilled / CrashLoopBackOff
kubectl describe pod hog | grep -A5 "Last State"
kubectl get pod hog -o jsonpath='{.status.qosClass}{"\n"}'
```

`hog` tries to hold 200Mi with a 100Mi limit. Exit code 137, reason OOMKilled, restarts forever. This is what a memory leak looks like in production.

Now CPU:

```sh
kubectl top pod -l lesson=06
```

`spinner` burns CPU with a `100m` limit and shows about 100m in `kubectl top`. Throttled, not killed.

### Unschedulable

PREDICT: what happens to a pod that requests 64 CPUs?

```sh
kubectl run huge --image=nginx:1.27-alpine --overrides='{"spec":{"containers":[{"name":"huge","image":"nginx:1.27-alpine","resources":{"requests":{"cpu":"64"}}}]}}'
kubectl get pod huge
kubectl describe pod huge | tail -3
kubectl delete pod huge
```

`Pending`, event `0/1 nodes are available: 1 Insufficient cpu`. The number one cause of Pending in real clusters.

### LimitRange and ResourceQuota

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: team-b
spec:
  limits:
    - type: Container
      default: {cpu: 200m, memory: 128Mi}
      defaultRequest: {cpu: 50m, memory: 64Mi}
      max: {cpu: "1", memory: 512Mi}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-b-quota
  namespace: team-b
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    pods: "5"
EOF
kubectl -n team-b rollout restart deploy web
kubectl -n team-b get pod -o jsonpath='{.items[0].spec.containers[0].resources}{"\n"}'   # defaults injected
kubectl -n team-b scale deploy web --replicas=10
kubectl -n team-b get deploy web                 # stuck below 10
kubectl -n team-b describe quota team-b-quota
kubectl -n team-b get events | grep -i quota | tail -2
```

Quota errors show up as events on the ReplicaSet, not the Deployment. Worth remembering when a rollout stalls silently.

## Checkpoint

```sh
kubectl auth can-i list pods --as=system:serviceaccount:team-a:reader -n team-a    # yes
kubectl get pod hog -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'   # OOMKilled
```

## Quiz

1. Role vs ClusterRole. Can a RoleBinding reference a ClusterRole? What does that give you?
2. A pod needs to list Secrets in its own namespace only. List the exact objects you create.
3. Requests 100m, limits 500m, the node is idle. How much CPU can the container use? Under contention?
4. Container memory: requests 100Mi, limits 100Mi, app uses 120Mi. What happens? Requests 100Mi, no limit, uses 120Mi?
5. Pod is Pending with "Insufficient memory" but `kubectl top node` shows 60% free. Explain.
6. Interview: "How do you give a CI pipeline access to deploy to one namespace and nothing else?"

<details>
<summary>Answers</summary>

1. Role is namespaced, ClusterRole is not. Yes, a RoleBinding can bind a ClusterRole: the subject gets those permissions only in the binding's namespace. That is how you reuse one `edit`-like ClusterRole across many namespaces without copying it.
2. ServiceAccount `x` in the namespace. Role with `apiGroups: [""]`, `resources: [secrets]`, `verbs: [list, get]`. RoleBinding subject `ServiceAccount x`, roleRef the Role. Pod spec `serviceAccountName: x`.
3. Idle: up to 500m. Contention: guaranteed at least 100m, shares above that proportional to requests versus other containers.
4. With limit: OOMKilled at 100Mi, exit 137, restart. Without limit: keeps running, can consume node memory. If the node runs out, the kubelet evicts pods, starting with BestEffort and those most over their request.
5. Scheduling is on requests, not usage. Other pods have reserved memory they are not using. Sum of requests hit capacity. Fix: right-size requests, or add nodes. Also check `kubectl describe node` Allocatable versus Capacity, system reserved eats some.
6. ServiceAccount in that namespace, Role granting create/update/patch/get/list on deployments, services, configmaps, secrets as needed, RoleBinding. Issue a token for the SA (`kubectl create token`, bound and short-lived) or better, OIDC federation from the CI provider. No ClusterRoleBinding, no `cluster-admin`. Verify with `kubectl auth can-i --list --as=system:serviceaccount:ns:ci`.
</details>

## Task

In namespace `team-a`, from scratch:

- ServiceAccount `deployer`
- Role `deployer` allowing `get, list, watch, create, update, patch` on `deployments` (apiGroup `apps`) and `get, list` on `pods`
- RoleBinding `deployer` binding them
- Deployment `quota-web`, 2 replicas, `nginx:1.27-alpine`, with requests cpu 50m memory 32Mi and limits cpu 200m memory 64Mi, running as `serviceAccountName: deployer`

Verify `kubectl auth can-i create deployments --as=system:serviceaccount:team-a:deployer -n team-a` is `yes` and `... delete pods ...` is `no`. Then `./check.sh`.

Clean up: `kubectl delete ns team-a team-b; kubectl delete -f limits.yaml`.
