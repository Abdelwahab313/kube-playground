# 12. Day-2 operations: observability, TLS, backup, upgrades

Goal: you have a workload in production. This lesson is about what keeps you calm at 3am: metrics you can query, logs you can search, certificates that renew themselves, backups you have actually restored, and an upgrade path that does not end in an outage.

Day 2 splits into a few jobs. None of them are write-once:

| Job | Tool here | Production (AWS/GCP/Azure) |
|---|---|---|
| Metrics | Prometheus + Grafana (kube-prometheus-stack) | Managed Prometheus, or Prometheus + Grafana self-hosted |
| Logs | Plain `kubectl logs` first, Loki/EFK later | CloudWatch Logs, Loki, Elastic |
| Certs | cert-manager | cert-manager + Let's Encrypt, or the cloud CA |
| Backup | etcd snapshot + manifest export; Velero for full cluster | Velero to S3, RDS snapshots for DBs |
| Upgrades | `kubeadm upgrade` flow (concept here) | Managed upgrades (EKS) or kubeadm (self-hosted) |

## A. Prometheus: the pipeline that powers autoscaling

In lesson 08 your HPA read CPU via metrics-server. Metrics-server serves only built-in metrics. Prometheus is the real system: it scrapes exporters (on nodes, pods, your apps) into a time series database and answers queries. The operator pattern you met with ingress-nginx (a controller watching custom objects) is reused: a **Prometheus Operator** Deployment watches `ServiceMonitor` objects and turns them into scrape configs.

```sh
helm install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts \
  --namespace monitoring --create-namespace \
  --set prometheus.prometheusSpec.replicas=1 \
  --set alertmanager.alertmanagerSpec.replicas=1
kubectl -n monitoring get pods          # 3 control plane pods, node-exporter daemonsets, kube-state-metrics
kubectl -n monitoring get servicemonitors,crds  # the operator's contract
```

EKS analogy: this is one for one what the "observability" dashboard vendors sell. You can point the Operator at any exporter with a ServiceMonitor.

### Look at numbers

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 80:80 &
```

Prom at `localhost:9090`, Grafana at `localhost:80` (admin/`kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d`). DB credentials are in a generated secret - the day-2 version of lesson 04. Query Prom:

```
up
node_memory_Active_bytes
kube_pod_container_status_restarts_total
```

Now correlate with the metrics you already had: `kubectl top pod` is a narrow window on the same data. The HPA of lesson 08 reads `container_cpu_usage_seconds_total`, which Prometheus now stores.

### A ServiceMonitor that actually scrapes

You already run an exporter: ingress-nginx controller exposes Prometheus metrics on port 10254. Point a ServiceMonitor at it:

```sh
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: {name: ingress-nginx, namespace: monitoring}
spec:
  selector:
    matchLabels: {app.kubernetes.io/instance: ingress-nginx}
  namespaceSelector: {any: true}
  endpoints:
  - {port: metrics, path: /metrics, interval: 30s}
EOF
kubectl -n monitoring get servicemonitors ingress-nginx
```

PREDICT: does Prometheus find the Service's named port `metrics`? Check the target page at `localhost:9090/targets`. You are scraping a live exporter with data - `up == 1` for it means health.

Now the common confusion. Create a ServiceMonitor for an app with no `/metrics` endpoint:

```sh
kubectl create ns metrics-demo
kubectl -n metrics-demo create deploy httpbin --image=mccutchen/go-httpbin --port=8080
kubectl -n metrics-demo expose deploy httpbin --port=8080
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata: {name: httpbin, namespace: metrics-demo}
spec:
  selector: {matchLabels: {app: httpbin}}
  endpoints: [{path: /metrics, port: "8080"}]
EOF
```

`Targets` page: state `Down`, reason "server returned HTTP status 404" - the pod answers, there is just no `/metrics`. `Up == 0` with a 4xx is *always* "app does not expose Prometheus". Production debugging: same answer for a service you think is scraped.

### Alerting

The chart ships AlertManager. Write rules as `PrometheusRule` objects:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata: {name: high-cpu, namespace: monitoring}
spec:
  groups:
  - name: cpu
    rules:
    - alert: NodeHighCPU
      expr: instance:node_cpu_utilization:ratio > 0.8
      for: 5m
      labels: {severity: warning}
      annotations: {summary: "node {{ $labels.instance }} CPU above 80% for 5m"}
```

`for: 5m` is what makes it an alarm and not a page. Configure AlertManager's receiver (Slack/PagerDuty/webhook) in values - it is a plain HTTP POST to a webhook, which is how you test it locally with `webhook.site` before connecting real notifications.

## B. Logs

Kubernetes has no log files. The app writes to stdout, containerd captures it, `kubectl logs` reads it. Everything you need to see in prod must come out of your app's stdout, or you do not see it. So: structured JSON logs + one line per event is a cluster-wide requirement, not a style preference.

```sh
kubectl logs -f deploy/api -n metrics-demo           # stream
kubectl logs deploy/api -n metrics-demo --since=10m  # backfill
kubectl logs -l app=web --tail=50                    # by label
kubectl logs deploy/api -n metrics-demo --previous   # dead container's last words
kubectl get events -w
```

Demo one line of agony: `CrashLoopBackOff` and `kubectl logs` shows nothing. That means the process died before printing. `--previous` or a readiness probe `kubectl exec` will tell you which. This is the drill from lesson 09 applied to "no logs at all" - which is itself a state you diagnose.

Production-grade log search is a collector (DaemonSet) shipping stdout to Loki/EFK + the cloud: `loki-stack` helm chart, or CloudWatch agent are drop-in at this point. The interface you use (`kubectl logs NAME`, then whatever search) is the thing the collector preserves.

## C. TLS with cert-manager

The internet insists on HTTPS. Ingress-nginx terminates TLS for you if you give it a certificate; cert-manager gives it certificates and renews them. Same operator pattern: a controller watching `Certificate` objects; issuers define *where* certs come from.

Install:

```sh
helm install cert-manager cert-manager \
  --repo https://charts.jetstack.io \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true
kubectl -n cert-manager get pods   # certificate controller, cainjector, webhook
```

PREDICT: what do you get from a `Let's Encrypt` issuer in a sandbox that cannot do DNS validation?

For local use a `selfsigned` issuer (production: `ClusterIssuer` pointing at Let's Encrypt ACME with `solvers` for HTTP-01 or DNS-01). `issuer.yaml` in this directory:

```sh
kubectl create ns shop
kubectl apply -f issuer.yaml
kubectl apply -f tls.yaml    # deploy api, svc, ingress with a TLS block + annotation
kubectl get certificate     # name  /   READY   /   SECRET  shop-tls / shop-tls ✓ / shop-tls
kubectl get secret shop-tls -o jsonpath='{.type}{"\n"}'   # kubernetes.io/tls
```

The magic is the annotation on the Ingress: `cert-manager.io/cluster-issuer: selfsigned-local`. cert-manager sees it, notices the `tls[].secretName: shop-tls` is empty, and materializes the secret automatically. You never touch the private key; that is the point (and the security reason for the pattern).

Test from your mac:

```sh
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -sk https://$NODE_IP/ -H "Host: shop.local" && echo " TLS ok"
curl -k https://$NODE_IP/ --resolve shop.local:443:$NODE_IP   # proper SNI resolution
```

`-k` is a lie. Do the real trust check against the issued CA:

```sh
CA=$(kubectl get secret shop-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)
curl --cacert <(echo "$CA") --resolve shop.local:443:$NODE_IP https://shop.local/
```

cert-manager renews automatically before expiry. In production "cert expired" is a cert-manager wiring bug, not a renewal job you run by hand.

## D. Backup and disaster recovery

Backup is meaningless until a restore has been rehearsed. Three things to back up:

1. **Cluster state**: what etcd (or kine here) stores. In KubeSolo:
   ```sh
   orb -m kubesolo sudo ls -la /var/lib/kubesolo/kine/       # kine.db lives here
   orb -m kubesolo sudo cp /var/lib/kubesolo/kine/kine.db /var/lib/kubesolo/kine/kine.db.bak.$(date +%s)
   ```
   Real clusters: `ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 snapshot save backup.db` (with certs). This is the "whole cluster is gone" restore.
2. **Manifests/config in git** (GitOps). If your cluster dies and your YAML lives in git, restore = `kubectl apply -R` or Argo CD resync. Volume data is the only loose end.
3. **App data**: your database. Lesson 08's CronJob pattern (`pg_dump` nightlies) or cloud snapshots. Stateless services are nowhere - that is the point of them.

Cluster-wide backup of everything (resources + PV data) is **Velero**: agentless install, schedules backups of cluster state and volume snapshots to object storage (S3), and does restore as a single command. That is the tool name-dropped in every DR interview. Practice it on kind with MinIO.

DR drill (this is what interviews and on-call measure):

```sh
# simulate the worst: cluster object store dies
kubectl delete ns shop
# restore from your git/YAML - from lesson 08 M6 that was "delete and reinstall in one command"
# restore a lost PVC: it was a volume in S3, Velero or the DB operator replays it
```

What you just proved: the app state lives in the object store or a volume; everything else is either in git or can be answered with "was rebuilt". Your backup file without a tested restore is a sedative, not a safety net.

## E. Upgrades

Version skew is real: `kubectl get nodes -o wide` shows kubelet versions drifting after a rolling node upgrade. Rule: the kubelet and every control plane component must be a supported combination - docs at kubernetes.io/releases/version-skew-policy. Practical consequences:

- **Kubelet may be a couple of minors *older* than the API server, never newer.** Rolling nodes one at a time is the point.
- Control plane first, workers after. `kubeadm upgrade plan`, drain+upgrade each node, uncordon.

The flow (kubeadm; same shape on bare metal / k3s):

```sh
# control plane
kubeadm upgrade plan
kubeadm upgrade apply v1.27.3
kubectl drain cp --ignore-daemonsets
# upgrade kubelet + kubectl on the node, restart kubelet, then:
kubectl uncordon cp
# each worker: drain -> upgrade kubelet/kubeadm -> uncordon
```

Managed clusters (EKS) abstract this to "click Upgrade", and the platform does it node-by-node under the same drain/PDB rules you practiced in lessons 08 and 10. Every upgrade in production runs the same sequence: back up (D) → validate current health (`kubectl get nodes`, `kubectl top`) → upgrade control plane → drain/upgrade/uncordon workers in waves honoring PDBs → run a smoke test (lesson 09's last quiz, first two minutes).

## Checkpoint

```sh
kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus    # Running
kubectl -n monitoring get servicemonitors                              # at least one, with a non-empty spec
kubectl -n monitoring get servicemonitors ingress-nginx -o jsonpath='{.spec.endpoints[0].path}'   # /metrics
kubectl -n cert-manager get pods                                        # Running
kubectl get certificate -n shop                                          # READY True
kubectl get secret shop-tls -n shop -o jsonpath='{.type}{"\n"}'        # kubernetes.io/tls
curl --cacert <(kubectl get secret shop-tls -n shop -o jsonpath='{.data.ca\.crt}' | base64 -d) \
  --resolve shop.local:443:$NODE_IP https://shop.local/                # 200, no -k
kubectl get crd prometheusrules.monitoring.coreos.com
```

## Quiz

1. Why does an HPA read metrics-server and Prometheus reads the same counter different ways? What metrics-server actually caches?
2. Prometheus Target `Down`, HTTP 404. What is the app doing?
3. `up == 0` for 2 targets. Name two directions this can go and the diagnostic for each.
4. cert-manager: what creates a secret named in `tls.secretName` and why do you never see the private key?
5. An ingress stops serving HTTPS with "no certificate". List the first three checks.
6. You can only restore three things from a dead cluster. What, and why these three?
7. How do you upgrade a node with zero downtime, relying on what from lessons 08/10?
8. Interview: "Walk me through what happens when Nightly backup runs and how you would restore after total data loss."

<details>
<summary>Answers</summary>

1. Both read kubelet's metrics endpoint (`/metrics/resource`), but metrics-server is a cache for the HPA/scheduler with short retention and no query language. Prometheus keeps an archive and does arbitrary queries. An HPA never queries Prometheus in vanilla k8s - it polls metrics-server. Management of the containers is the API, statistics is an implementation detail each consumer caches once.
2. It exposes no `/metrics` - the export endpoint is missing, or the exporter listens on a different port/path than the ServiceMonitor says. 4xx from a scrape = "app answered the TCP connection, disagreed about the path". Check the app's exporter port and the endpoint's `port` field.
3. Could be the target is truly down (kill it: `kubectl delete pod`) and nothing is scraped; or the pod is up but the scrape endpoint itself is unreachable from Prometheus (often because the Service selector misses). Diagnose with the target page reason (`context deadline exceeded` = network/selector, `server returned HTTP status 404` = wrong path/port), then curl the endpoint from a scrape probe pod.
4. cert-manager's controller watches `Certificate` + the `cert-manager.io/cluster-issuer` annotation and provisions whatever the issuer says (ACME, selfsigned, vault). The private key is generated in-cluster and held in the Secret; ACME never sees it and rotatation happens automatically. You "never see" keys because the controller manages them - a human would be a privilege leak.
5. (a) Does the Secret named in `tls.secretName` exist and have a `tls.crt`? (b) Is the `Certificate` object Ready (`kubectl get certificate`), and what does its status say? (c) The issuer: selfsigned for testing, ACME for prod, and is `cert-manager.io/cluster-issuer` spelled exactly? The failure almost always reads "no TLS secret for x" in the ingress controller logs first.
6. Cluster state (etcd snapshot), the PVC/volume data, and the YAML/config in git. Stateless services are rebuilt automatically. Those three are exactly the three things that hold state your controllers cannot re-derive.
7. Node-by-node with `kubectl drain --ignore-daemonsets` (lesson 10), PDB `minAvailable` guarding each Deployment (lesson 08), topology spread so the drained node's replicas have somewhere to go (lesson 10), and `uncordon` when the node is back. Zero downtime means the second node starts draining only after the first's PDB-protected deployments are Ready - the secret is the order and the PDBs.
8. Nightly: a CronJob (lesson 08) runs `pg_dump`/Kind snapshot to durable storage (S3-Velero, or `etcdctl snapshot`). Restore: recreate cluster from a snapshot (etcd), reapply all manifest+YAML from git (or Velero `restore`), and replay DB volume from the backup. The answer they want: backup happened regularly, restore was rehearsed, roles and secrets come back from source (git), and the state is one command away. Never say "we back up" without adding "and I've restored it in a drill".
</details>

## Task

Name `shop` namespace is gone (you killed it in the DR drill). Rebuild it so it passes all checks:

- Namespace `shop`
- cert-manager `selfsigned` `ClusterIssuer` named `selfsigned-local` (it may already exist from the walkthrough - reuse it)
- Deployment `api` 1 replica, `nginxinc/nginx-unprivileged:1.27-alpine`, port 8080, labels `app: api`
- Service `api` ClusterIP 8080
- Ingress `shop` host `shop.local`, class `nginx`, path `/` → svc `api`, with `tls.secretName: shop-tls` and annotation `cert-manager.io/cluster-issuer: selfsigned-local`
- Ingress-nginx (installed in lesson 03) and cert-manager present

Verify then `./check.sh`:

```sh
kubectl get certificate shop-tls -n shop        # READY True
curl --cacert <(kubectl get secret shop-tls -n shop -o jsonpath='{.data.ca\.crt}' | base64 -d) \
  --resolve shop.local:443:$NODE_IP https://shop.local/
```

Clean up when done: `helm uninstall kube-prometheus-stack -n monitoring; kubectl delete ns monitoring metrics-demo shop; helm uninstall cert-manager -n cert-manager; kubectl delete ns cert-manager`. The issuer is a ClusterIssuer, so `kubectl delete clusterissuer selfsigned-local; kubectl delete crd certificates.cert-manager.io ...` - or simpler, leave the playground for the next learner to recreate with `helm uninstall cert-manager` and the issuer gone.