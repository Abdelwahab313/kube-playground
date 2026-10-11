# 10. Scheduling and node operations (multi-node, kind)

Goal: the topics KubeSolo cannot show you. Taints and tolerations, affinity, topology spread, and what happens during maintenance and failure on a real cluster. This is the biggest gap between "knows k8s" and "operates k8s", and a heavy CKA topic.

You need a multi-node cluster. OrbStack's Docker runs kind. Your KubeSolo cluster stays untouched; everything here runs on a separate `kind-multi` cluster.

## Concept

The scheduler places a pod on a node by first **filtering** (which nodes can host it) then **scoring** (which is best). Four knobs, from dumb to smart:

| Knob | Filters | Scores | Says |
|---|---|---|---|
| `nodeSelector` | yes | no | must run on a node with labels `k=v`. Fixed. No "or". |
| `nodeAffinity` | yes | yes (preferred) | hard rule (`requiredDuringScheduling`) or a soft preference (`preferredDuringScheduling`). Unlike nodeSelector it supports `In`, `NotIn`, `Exists`. |
| `podAffinity`/`podAntiAffinity` | yes | yes | run near (or away from) pods with label X. |
| `topologySpreadConstraints` | no | yes | spread replicas evenly across nodes/zones. |

**Taints and tolerations** are the only feature that works the other way: the *node* declares "repel pods unless they tolerate me". Three effects:

- `NoSchedule`: new pods stay Pending. Old ones keep running.
- `PreferNoSchedule`: soft, try to avoid.
- `NoExecute`: evict running pods that lack the toleration, and block new ones.

This is how a cluster is actually run, and it changes the mental model:

- **Built-in taints** maintain the cluster for you. When a node dies the node-lifecycle controller taints it `node.kubernetes.io/not-ready:NoExecute`; pods that do not tolerate it (everyone, after 5 minutes) are evicted and a healthy node takes them. That is self-healing at the node level.
- **`cordon`** is a human doing the same thing for planned maintenance: mark `SchedulingDisabled`, already-running pods keep serving, new pods stay Pending until you `drain`.
- **`drain`** evicts a node cleanly: respects PDBs, runs `preStop` hooks, gives deployments time to stand up replacements elsewhere, then marks pods dead so controllers recreate them.

Rule of thumb: prefer higher-level affinity + topology spread + PDBs over hand-placing pods. The cluster moves work for you; fighting it is how you wake up at 3am.

## Setup

Create the cluster and tell kubectl to talk to it.

```sh
kind create cluster --config kind-multi.yaml          # 1 control-plane, 2 workers
kubectl config get-contexts                            # kind-multi appears
kubectl config use-context kind-multi
kubectl get nodes -o wide                              # kind-multi-control-plane, -worker, -worker2
```

PREDICT: `kubectl get nodes` shows taints for which node(s)?

The control-plane node is tainted `node-role.kubernetes.io/control-plane:NoSchedule` and runs no workload. The workers are clean.

Read `kind-multi.yaml`. It is declarative cluster config; if you delete the cluster you rebuild it with one command. Same spirit as your app YAML.

## Walkthrough

### nodeSelector: the dumb knob and its classic failure

Label the workers like availability zones:

```sh
kubectl label node kind-multi-worker  zone=az1
kubectl label node kind-multi-worker2 zone=az2
```

PREDICT: where does this pod land?

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: fixed}
spec:
  nodeSelector: {zone: az1}
  containers: [{name: app, image: nginx:1.27-alpine}]
EOF
kubectl get pod fixed -o wide      # kind-multi-worker
```

Now the classic bug. Move the label:

```sh
kubectl label node kind-multi-worker zone-          # the trailing dash removes the label
kubectl get pod fixed               # PREDICT
kubectl get pod fixed -o yaml | grep -i condition   # Readiness gates: node doesn't match
```

`Pending`, event `0/3 nodes are available: 1 node(s) had untolerated taint, 2 node(s) didn't match node selector`. No node matches. That is exactly what "insufficient" Pending events look like when someone mistypes a label value in prod. Remove the pod and put the label back:

```sh
kubectl delete pod fixed
kubectl label node kind-multi-worker zone=az1
```

### nodeAffinity: hard rule + soft preference

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: preferred}
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 1
        preference:
          matchExpressions:
          - {key: zone, operator: In, values: [az1]}
  containers: [{name: app, image: nginx:1.27-alpine}]
EOF
kubectl get pod preferred -o wide   # both workers are valid, az1 merely scores higher
```

`requiredDuringScheduling...` behaves like nodeSelector but supports expressions. `NotIn: [az1]` keeps pods off a node for example. Edit the pod to use `requiredDuringSchedulingIgnoredDuringExecution` and watch a no-match go Pending, same as before.

### podAntiAffinity: spread API replicas apart

This is the production pattern for replicas that must never sit on the same node (or same zone, for HA).

```sh
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: api}
spec:
  replicas: 2
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels: {app: api}
            topologyKey: kubernetes.io/hostname
      containers: [{name: app, image: nginx:1.27-alpine}]
EOF
kubectl get pods -l app=api -o wide   # one per worker
kubectl scale deploy api --replicas=4
kubectl get pods -l app=api -o wide   # still 2 nodes, 2 pods each is fine; anti-affinity is per-node
```

`topologyKey: kubernetes.io/hostname` means "different node". For zone-level HA use `topology.kubernetes.io/zone`. `required` blocks scheduling when it cannot be satisfied (e.g. 3 replicas, big anti-affinity, 2 nodes → third stays Pending). Prefer `preferred` unless failure of the preference is unacceptable.

### Taints and tolerations

Dedicate `kworker2` like a database node:

```sh
kubectl taint node kind-multi-worker2 dedicated=db:NoSchedule
```

PREDICT: what happens to this pod?

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: no-tol}
spec:
  containers: [{name: app, image: nginx:1.27-alpine}]
EOF
kubectl get pod no-tol                 # Pending
kubectl describe pod no-tol | tail -4  # "untolerated taint"
```

The scheduler could put it on az1 or az2, but the node says no. Add the toleration:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: with-tol}
spec:
  tolerations:
  - {key: dedicated, operator: Equal, value: db, effect: NoSchedule}
  nodeSelector: {zone: az2}     # force it onto the tainted node so you can see it land there
  containers: [{name: app, image: nginx:1.27-alpine}]
EOF
kubectl get pod with-tol -o wide       # kind-multi-worker2
```

Now `NoExecute`: it evicts. Taint the node a running workload sits on and watch the Deployment heal itself onto the other worker.

```sh
kubectl delete pod no-tol with-tol
kubectl scale deploy api --replicas=2
kubectl get pods -l app=api -o wide
kubectl taint node kind-multi-worker2 dedicated=db:NoExecute
kubectl get pods -l app=api -w        # pod on worker2 terminates, Deployment makes a new one on worker
kubectl taint node kind-multi-worker2 dedicated=db:NoExecute-
```

This is exactly the built-in machinery behind node failure (below).

### topologySpreadConstraints: even distribution

```sh
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: spread}
spec:
  replicas: 4
  selector: {matchLabels: {app: spread}}
  template:
    metadata: {labels: {app: spread}}
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: zone
        whenUnsatisfiable: DoNotSchedule
        labelSelector: {matchLabels: {app: spread}}
      containers: [{name: app, image: nginx:1.27-alpine}]
EOF
kubectl get pods -l app=spread -o wide   # 2 on az1, 2 on az2: skew 0
kubectl get nodes -l zone --show-labels
```

Scale to 5: PREDICT. One node gets 3, the other 2 → skew becomes 1, allowed (`maxSkew: 1`). Scale to 6 → still 3/3, they cannot do better. That is the "spread as evenly as the topology allows" contract. `topologyKey: kubernetes.io/hostname` spreads per node.

### cordon, drain, node maintenance

Planned maintenance: take `kind-multi-worker` out of rotation without killing what runs.

```sh
kubectl cordon kind-multi-worker
kubectl get nodes                    # SchedulingDisabled on worker
kubectl scale deploy api --replicas=4
kubectl get pods -l app=api -o wide  # the 2 new ones land on worker2; worker's pods keep running
```

Nothing moves yet. That is the point of cordon: quiesce a node for a while without traffic loss. When ready:

```sh
kubectl drain kind-multi-worker --ignore-daemonsets --delete-emptydir-data
```

`--ignore-daemonsets` is needed whenever you have DaemonSets (kind's default CNI runs one per node; on EKS that is `aws-node`/`kube-proxy` and there are always daemons). Draining evicts each pod: it politely leaves (preStop, PDB check), the Deployment controller sees fewer replicas and rebuilds them on `worker2`. The PDB you built in lesson 08 is what lets a Deployment survive a drain without going below your availability floor.

PREDICT: `api` finished draining with how many Ready replicas?

```sh
kubectl get pods -l app=api -o wide
kubectl describe node kind-multi-worker | grep -A4 Unschedulable
```

Bring it back:

```sh
kubectl uncordon kind-multi-worker
kubectl scale deploy api --replicas=4
kubectl get pods -l app=api -o wide   # spreads again, node is drainsable again
```

A drained node will not take new pods until `uncordon`. Full cluster wizardry sequence for node replace: `cordon` → `drain` → `docker stop` old node container → `kind create node`/recreate → `uncordon`.

### Node failure

Death is different from maintenance: nothing drains, something must notice.

```sh
kubectl run stranded --image=nginx:1.27-alpine --restart=Never
kubectl get pod stranded -o wide      # note the node
docker stop kind-multi-worker2
kubectl get nodes                     # NotReady after ~40s
kubectl get pod stranded -o wide      # still "Running" - the kubelet died; stale is normal for a while
kubectl get pods -l app=api -o wide   # Deployment pods there are also stale-but-seen-as-Running
```

Wait is the honest answer. After about 5 minutes the node-lifecycle controller taints the dead node `node.kubernetes.io/not-ready:NoExecute`; only pods with a matching toleration survive (control-plane components and things you intentionally protect). Everything else is evicted, and the Deployment controller rebuilds the replicas on the living node.

```sh
docker start kind-multi-worker2
kubectl wait --for=condition=Ready node/kind-multi-worker2 --timeout=120s
kubectl get nodes
# the Deployment heals itself shortly after the node is marked NotReady; stranded is gone
# (a bare pod is not restarted anywhere - lesson 01, now with real consequences)
```

Core lesson: **Deployments survive, bare pods do not.** Every workload in production is behind a Deployment, StatefulSet, DaemonSet or Job.

## Checkpoint

```sh
kubectl get nodes --show-labels         # 3 Ready, zone on each worker
kubectl get pods -l app=api -o wide     # 4 replicas, spread across both workers
kubectl get pods -l app=spread -o wide  # spread across zones, skew <= 1
kubectl get node kind-multi-worker -o jsonpath='{.spec.taints}'  # empty, node usable
```

## Quiz

1. Node is tainted `x=:NoSchedule`. A pod with no toleration is Pending. Name one legitimate production node you would taint and why.
2. `nodeSelector: {zone: az1}` and the pod is Pending. What do you check, in order?
3. `required` podAntiAffinity on `topologyKey: kubernetes.io/hostname` with 6 replicas on 2 nodes. What happens?
4. Cordon vs drain. What does each do that the other does not?
5. Why does every drain include `--ignore-daemonsets`?
6. Node dies. Why is the Deployment's pod still listed as `Running` for minutes, and what eventually fixes it?
7. Interview: "How do you schedule 3 API replicas so two can never be on the same node, and the pair spans zones?"

<details>
<summary>Answers</summary>

1. Control-plane nodes (already tainted `NoSchedule`), dedicated DB nodes, GPU nodes, spot-pool nodes you only want for burst load. Anything you want to repel general workloads from unless explicitly tolerated.
2. Two things first: `kubectl get nodes --show-labels | grep az1` (does the label exist at all) then `kubectl describe pod | tail` (event says "didn't match node selector" vs "untolerated taint"). A typo in the value is the usual cause. Then check whether the node matching is Ready and not cordoned.

3. Third stays Pending. Required anti-affinity cannot be satisfied, so it is never scheduled (the filter rejects all nodes). The event will say so. Fix: scale to 2 per node, use `preferred`, or reduce replicas. This is a real incident pattern: autoscaler grows replicas, node pool can't place them, pods hang.
4. Cordon only blocks new scheduling (`SchedulingDisabled`), running pods stay. Drain evicts and marks existing pods for termination so controllers rebuild elsewhere, then blocks new pods. Cordon is "stop the bleeding", drain is "empty the node".
5. DaemonSets run one pod on every node by design and cannot be evicted elsewhere - draining would hang forever on them. Same reason you add `--delete-emptydir-data` for nodes where a DaemonSet uses emptyDir. On EKS the `aws-node`/`kube-proxy` daemons are always there.
6. The kubelet that would report the pod status is dead, so the API server still sees the last-known state. After the node-lifecycle controller's grace period (~5 min) it taints the node `not-ready:NoExecute`, pods without a toleration are evicted, the Deployment controller counts them down and rebuilds on a healthy node. Same mechanism you practiced with the manual taint.
7. `topologySpreadConstraints` with `topologyKey: zone`, `maxSkew: 1`, `whenUnsatisfiable: DoNotSchedule` to spread across zones, plus `podAntiAffinity.requiredDuringScheduling` with `topologyKey: kubernetes.io/hostname` so no node holds two. PDB with `minAvailable: 2` then lets you drain one node without breaching.
</details>

## Task

On `kind-multi`, from memory:

- Label both workers `zone=az1` (the walkthrough left them `az1` and `az2`; this task models one AZ with two nodes)

```sh
kubectl label node kind-multi-worker  zone=az1
kubectl label node kind-multi-worker2 zone=az1
```

- A Deployment `cache`, 2 replicas, `redis:7-alpine`, labels `app: cache`
- It must land only on `zone=az1` nodes (`nodeSelector`)
- No two replicas on the same node (`podAntiAffinity`, required, `kubernetes.io/hostname`)
- `topologySpreadConstraints` placing them evenly across `zone=az1`'s nodes (`maxSkew: 1`)
- Taint `kind-multi-worker2` with `dedicated=cache:NoSchedule`; give the Deployment the matching toleration

Verify:

```sh
kubectl get pods -l app=cache -o wide     # both on az1, one per node, both Ready
kubectl get nodes -l zone=az1 --show-labels
./check.sh
```

Then clean up the cluster entirely:

```sh
cd ..   # from the lesson dir
kind delete cluster --name multi
```

A fresh learner runs `kind create cluster --config kind-multi.yaml` and starts again. That is reproducible infra, and it is what GitOps wants from cluster bootstrap too. Deleting the cluster removes its nodes, labels and taints with it.