# Kubernetes playground

Hands-on path from "I know Docker, Compose and ECS" to "I can run and debug workloads on Kubernetes in a job interview and on day one".

Cluster: KubeSolo v1.2.0 (Kubernetes v1.35), single node, running inside the OrbStack machine `kubesolo`. See `lessons/00-setup` for how it is wired and how to recover it.

## How to use this repo

Each lesson lives in `lessons/NN-topic/` and has the same shape:

1. **Concept** in a few paragraphs, always mapped to the Docker/Compose/ECS thing you already know.
2. **Walkthrough** with commands. Lines marked `PREDICT:` ask you to guess the outcome before running. Write the guess down, then run. Being wrong is the lesson.
3. **Checkpoint** commands so you know you are on track.
4. **Quiz**. Answer out loud or in a scratch file, then open the `<details>` block.
5. **Task**. Something to build without step-by-step help. Run `./check.sh` in the lesson directory to grade it.
6. **Clean up** so the next lesson starts from an empty cluster.

Do not copy YAML from the lesson files on the task. Type it. Muscle memory for `apiVersion`, `metadata`, `spec.selector`, `spec.template` is what gets tested in interviews and what saves you at 2am.

## Mental map from ECS and Compose

| You know | Kubernetes | Notes |
|---|---|---|
| Container | Container | Same thing, still OCI images |
| Task definition | Pod spec | One or more containers sharing network and volumes |
| Running task | Pod | Ephemeral. Nothing restarts a bare pod on another node |
| ECS service | Deployment | Desired replicas, rolling updates, rollback |
| Daemon scheduling strategy | DaemonSet | One pod per node |
| Scheduled task | CronJob | Creates Jobs, which create Pods |
| One-off `run-task` | Job | Runs to completion, retries |
| Service discovery / Cloud Map | Service (ClusterIP) + DNS | `name.namespace.svc.cluster.local` |
| Target group + ALB | Service + Ingress | Ingress needs a controller installed |
| NLB | Service type LoadBalancer | KubeSolo assigns the node IP |
| Task env vars / SSM params | ConfigMap / Secret | Injected as env or mounted files |
| EFS volume | PersistentVolumeClaim | Storage class provisions the volume |
| Task IAM role | ServiceAccount + RBAC | Permissions inside the cluster |
| Capacity provider / ASG | Node pool | One node here |
| CPU/memory in task def | `resources.requests` and `limits` | Requests schedule, limits kill |
| Compose file | Helm chart or Kustomize | Templating and environments |
| `docker compose up` | `kubectl apply -f` | Declarative, idempotent |
| `docker logs` / `exec` | `kubectl logs` / `exec` | Same idea, add `-n namespace` |
| ECS cluster | Namespace (roughly) | Logical partition inside one cluster |

## Curriculum

| # | Lesson | You will be able to | Est. time |
|---|---|---|---|
| 00 | [Setup](lessons/00-setup/README.md) | Reach the cluster from your mac, know how to fix it | 30 min |
| 01 | [Pods and kubectl](lessons/01-pods/README.md) | Run, inspect, exec into, and kill pods. Read YAML fluently | 2 h |
| 02 | [Deployments](lessons/02-deployments/README.md) | Rolling updates, rollbacks, probes, replica self-healing | 3 h |
| 03 | [Services and networking](lessons/03-services-networking/README.md) | ClusterIP, NodePort, LoadBalancer, DNS, Ingress | 3 h |
| 04 | [Config and secrets](lessons/04-config-secrets/README.md) | ConfigMap and Secret as env and files, config rollouts | 2 h |
| 05 | [Storage](lessons/05-storage/README.md) | PVC, PV, StorageClass, StatefulSet, data survives pod death | 2 h |
| 06 | [Namespaces, RBAC, resources](lessons/06-namespaces-rbac-resources/README.md) | Isolate teams, least-privilege service accounts, OOMKill, quotas | 3 h |
| 07 | [Helm and Kustomize](lessons/07-helm-kustomize/README.md) | Package an app, install public charts, dev/prod overlays | 3 h |
| 08 | [Real app project](lessons/08-real-app/README.md) | Port a Compose stack: API, worker, DB, cache, Jobs, HPA, PDB | 1 week |
| 09 | [Debug drills](lessons/09-debug-drills/README.md) | Fix broken manifests fast. The interview lesson | ongoing |
| 10 | [Scheduling and node ops](lessons/10-scheduling-ops/README.md) | Taints, tolerations, affinity, `kubectl drain`, multi-node on kind | 3 h |
| 11 | [Security](lessons/11-security/README.md) | restricted securityContext, PSA, imagePullSecrets, NetworkPolicy | 3 h |
| 12 | [Day-2 ops](lessons/12-observability-day2/README.md) | Prometheus, cert-manager TLS, backups, upgrades | 4 h |

Read `REFERENCE.md` whenever you forget a command or a YAML skeleton. It also has the interview question bank.

## Progress

Tick as you pass each `check.sh`.

- [ ] 00 setup
- [ ] 01 pods
- [ ] 02 deployments
- [ ] 03 services and networking
- [ ] 04 config and secrets
- [ ] 05 storage
- [ ] 06 namespaces, RBAC, resources
- [ ] 07 helm and kustomize
- [ ] 08 real app
- [ ] 09 debug drills, all solved under 5 minutes each
- [ ] 10 scheduling and node ops (kind, 3 nodes)
- [ ] 11 security hardening
- [ ] 12 day-2 ops: observability, TLS, backup, upgrade

## After this repo

- Lesson 10 runs on an extra multi-node `kind` cluster (`lessons/10-scheduling-ops/kind-multi.yaml`); destroy it at the end with `kind delete cluster --name multi`. Lessons 11 and 12 run back on KubeSolo. Both contexts live in `~/.kube/config` - switch with `kubectl config use-context`.
- CKA (Certified Kubernetes Administrator) maps almost one-to-one onto lessons 01 to 11. If you want the certificate, do killer.sh practice sessions after lesson 11.
- GitOps with Argo CD or Flux is the usual next step in k8s-heavy companies. Lesson 12's backup section (manifests in git, Velero, `etcdctl snapshot`) is the discussion material for it.
