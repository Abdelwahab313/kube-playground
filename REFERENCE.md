# Reference

Cheat sheet, YAML skeletons, debug flow, interview bank. Keep it open in a split.

## kubectl

```sh
# context and namespace
kubectl config get-contexts
kubectl config set-context --current --namespace=dev

# read
kubectl get pods -o wide                      # add -A for all namespaces, -w to watch
kubectl get pod NAME -o yaml                  # the truth, including status
kubectl describe pod NAME                     # events at the bottom, read them first
kubectl logs NAME [-c container] [-f] [--previous]
kubectl get events --sort-by=.metadata.creationTimestamp
kubectl explain deployment.spec.strategy      # docs for any field, offline

# act
kubectl apply -f file.yaml                    # create or update
kubectl delete -f file.yaml
kubectl exec -it NAME -- sh
kubectl port-forward svc/NAME 8080:80
kubectl run tmp --image=busybox:1.36 --restart=Never --rm -it -- sh   # throwaway pod
kubectl debug -it NAME --image=busybox:1.36 --target=CONTAINER        # ephemeral container

# deployments
kubectl rollout status deploy/NAME
kubectl rollout history deploy/NAME
kubectl rollout undo deploy/NAME [--to-revision=N]
kubectl set image deploy/NAME CONTAINER=IMAGE:TAG
kubectl scale deploy/NAME --replicas=3

# generate YAML without creating (learn the skeletons)
kubectl create deploy web --image=nginx --dry-run=client -o yaml
kubectl expose deploy web --port=80 --dry-run=client -o yaml
kubectl create configmap cfg --from-literal=k=v --dry-run=client -o yaml

# permissions
kubectl auth can-i list pods --as=system:serviceaccount:dev:api
kubectl auth whoami

# resource usage (needs metrics server)
kubectl top pod
kubectl top node
```

Label selectors: `-l app=web`, `-l 'env in (dev,staging)'`, `-l app!=web`.

jsonpath: `kubectl get pod -o jsonpath='{.items[*].status.podIP}'`.

## YAML skeletons

Every object: `apiVersion`, `kind`, `metadata`, `spec`. Status is written by the cluster, never by you.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels: {app: web}
spec:
  replicas: 2
  selector:
    matchLabels: {app: web}          # must match template labels
  strategy:
    type: RollingUpdate
    rollingUpdate: {maxSurge: 1, maxUnavailable: 0}
  template:
    metadata:
      labels: {app: web}
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports: [{containerPort: 80}]
        env:
        - {name: MODE, value: prod}
        - name: DB_PASS
          valueFrom: {secretKeyRef: {name: db, key: password}}
        envFrom:
        - configMapRef: {name: web-cfg}
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {memory: 128Mi}
        readinessProbe:
          httpGet: {path: /, port: 80}
          periodSeconds: 5
        livenessProbe:
          httpGet: {path: /, port: 80}
          initialDelaySeconds: 10
        volumeMounts:
        - {name: cfg, mountPath: /etc/app, readOnly: true}
      volumes:
      - name: cfg
        configMap: {name: web-cfg}
```

```yaml
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  type: ClusterIP            # NodePort | LoadBalancer
  selector: {app: web}       # matches POD labels, not deployment labels
  ports:
  - {port: 80, targetPort: 80}
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: web}
spec:
  ingressClassName: nginx
  rules:
  - host: web.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend: {service: {name: web, port: {number: 80}}}
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Gi}}
  # storageClassName omitted = default class (local-path here)
```

```yaml
apiVersion: batch/v1
kind: CronJob
metadata: {name: report}
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - {name: job, image: busybox:1.36, command: [sh, -c, "date; echo done"]}
```

## Taints, tolerations, affinity, node ops

```sh
# taint / tolerate
kubectl taint nodes worker2 dedicated=cache:NoSchedule
kubectl taint nodes worker2 dedicated=cache:NoExecute    # evict running pods without toleration
kubectl taint nodes worker2 dedicated-                  # remove

# node maintenance (lesson 08: PDBs guard this)
kubectl drain node --ignore-daemonsets [--delete-emptydir-data]
kubectl uncordon node
kubectl cordon node        # no new pods, running pods stay

# node failure: kubectl get node shows NotReady; wait ~5 min for not-ready:NoExecute eviction
kubectl get node -o jsonpath='{.spec.taints}'
```

```yaml
# nodeSelector
spec:
  nodeSelector: {zone: az1}
# node affinity (soft: preferDuringSchedulingIgnoredDuringExecution)
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - {key: zone, operator: In, values: [az1]}
# pod anti-affinity: keep replicas off the same node
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels: {app: cache}
        topologyKey: kubernetes.io/hostname
# spread across failure domains (maxSkew)
spec:
  topologySpreadConstraints:
  - {maxSkew: 1, topologyKey: zone, whenUnsatisfiable: DoNotSchedule,
     labelSelector: {matchLabels: {app: cache}}}
# toleration
spec:
  tolerations:
  - {key: dedicated, value: cache, operator: Equal, effect: NoSchedule}
```

Match expressions: `In`, `NotIn`, `Exists`, `DoesNotExist`. Taint effects: `NoSchedule` (don't place), `PreferNoSchedule` (try not to), `NoExecute` (evict too). System taints (`node.kubernetes.io/not-ready`) are added automatically on failure - you do not add them.

## Security

```yaml
# restricted-profile container. Run as a non-root UID, drop ALL caps
securityContext:
  runAsNonRoot: true
  runAsUser: 101
  runAsGroup: 101
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  seccompProfile: {type: RuntimeDefault}
  capabilities: {drop: [ALL]}
# pod-level seccomp for everything in the pod
spec:
  securityContext:
    seccompProfile: {type: RuntimeDefault}
# writable scratch on a read-only container
volumeMounts:
- {name: tmp, mountPath: /tmp}
volumes: [{name: tmp, emptyDir: {}}]
```

Admission: put `restricted` (or `baseline`) on the namespace, not one pod at a time.

```sh
kubectl label ns secure pod-security.kubernetes.io/enforce=restricted
kubectl create secret docker-registry regcred --docker-server=registry.example.com --docker-username=ci --docker-password="${REGISTRY_TOKEN}" --docker-email=ci@example.com -n secure
kubectl patch sa default -p '{"imagePullSecrets":[{"name":"regcred"}]}' -n secure
```

Read-only root failure mode: works in dev, fails in production because the image writes somewhere you never mounted. Diagnose with `kubectl logs --previous`.

## Certificates and observability (day 2)

```sh
helm install cert-manager cert-manager --repo https://charts.jetstack.io --namespace cert-manager --create-namespace --set crds.enabled=true
helm install kube-prometheus-stack kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --namespace monitoring --create-namespace --set prometheus.prometheusSpec.replicas=1 --set alertmanager.alertmanagerSpec.replicas=1
# service monitor -> scrape config
kubectl get servicemonitors -A
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 80:80 &
kubectl get certificate -A          # cert-manager status
```

Who writes the ingress cert: `cert-manager.io/cluster-issuer` annotation on the Ingress + `tls[].secretName`; cert-manager watches the `Certificate` object and materializes the Secret. You never touch the private key.

Backup: `etcdctl snapshot save` (etcd) or copy `kine.db` (KubeSolo: `/var/lib/kubesolo/kine/`), manifests in git, DB dumps via CronJob. Velero for whole-cluster (resources + PV) to S3.

## Debug flow

Run this in order. Stop at the first thing that is wrong.

1. `kubectl get pods` and read STATUS and RESTARTS.
2. `kubectl describe pod NAME`, scroll to Events.
3. Match the status:

| Status | Meaning | Look at |
|---|---|---|
| `Pending` | Not scheduled | Events: insufficient cpu/memory, PVC unbound, node selector, taints |
| `ContainerCreating` for long | Volume or image pull stuck | Events: mount failure, image pull in progress, secret/configmap missing |
| `ImagePullBackOff` / `ErrImagePull` | Cannot pull image | Image name and tag, registry auth (`imagePullSecrets`) |
| `CreateContainerConfigError` | Env or volume references missing object | Events: configmap/secret key not found |
| `CrashLoopBackOff` | Container exits repeatedly | `kubectl logs NAME --previous`, command, entrypoint, missing env |
| `OOMKilled` (in describe, Last State) | Exceeded memory limit | Raise limit or fix leak |
| `Running` but `0/1 READY` | Readiness probe failing | Probe path, port, app not listening yet |
| `Running`, restarts climbing | Liveness probe failing | Probe too aggressive, app slow to start, use startupProbe |
| `Completed` | Job or pod with restartPolicy Never finished | Expected for Jobs |
| `Terminating` forever | Finalizer or stuck process | `kubectl get pod -o yaml` finalizers, `--grace-period=0 --force` last resort |

4. Service not reachable: `kubectl get endpointslices -l kubernetes.io/service-name=NAME`. Empty endpoints means selector does not match pod labels or pods not Ready.
5. DNS: `kubectl run tmp --image=busybox:1.36 --rm -it --restart=Never -- nslookup NAME.NAMESPACE.svc.cluster.local`.
6. Nothing works: `kubectl get nodes`, `kubectl get events -A --sort-by=.metadata.creationTimestamp | tail`.

## Interview question bank

Write your answer, then check the lesson.

**Basics**
- What is a Pod and why is it not just a container? (01)
- Difference between a Deployment, ReplicaSet and Pod. Who creates what? (02)
- What happens step by step when you run `kubectl apply -f deployment.yaml`? (02)
- Liveness vs readiness vs startup probe. What happens when each fails? (02)
- What is a Service and how does it find its pods? (03)
- ClusterIP vs NodePort vs LoadBalancer vs Ingress. When to use each. (03)
- How does DNS work inside the cluster? What does `ndots:5` do? (03)
- ConfigMap vs Secret. Are Secrets encrypted? (04)
- How do you roll pods when a ConfigMap changes? (04)
- PV vs PVC vs StorageClass. What does `WaitForFirstConsumer` mean? (05)
- StatefulSet vs Deployment. Why does a database want a StatefulSet? (05)
- Requests vs limits. What happens at each boundary? (06)
- What is a ServiceAccount, Role, RoleBinding, ClusterRole? (06)
- Helm vs Kustomize. When would you pick each? (07)
- What is a HorizontalPodAutoscaler and what does it need to work? (08)
- What is a PodDisruptionBudget for? (08)

**Scheduling and nodes**
- Taint vs toleration vs affinity. Which side writes which? (10)
- You need replicas of a cache on different nodes. What do you use? (10)
- Walk through a zero-downtime node upgrade, drain and uncordon included. (10, 12)
- What happens to pods on a node that dies? Who evicts them and when? (10)
- `dedicated=cache:NoSchedule` exists but the pod is Pending. What do you check? (10)

**Security**
- What makes a pod "restricted"? Name the securityContext fields. (11)
- `runAsNonRoot: true` + image runs as root. What exactly fails? (11)
- What is registered on a ServiceAccount with a docker-registry Secret? Why does a pod need it? (11)
- A namespace with `enforce=restricted` but an old Deployment in it. What happens and why? (11)
- Why does `readOnlyRootFilesystem` work in dev and break in production? (11)

**Day 2**
- Prometheus Target `Down`. What does the reason tell you? (12)
- How does a ServiceMonitor become a scrape config? Who does it? (12)
- What creates the ingress TLS secret and why do you never see the private key? (12)
- Name the three things you restore from a dead cluster. Why these three? (12)
- What is the difference between backing up and being able to restore? (12)

**Debugging**
- Pod stuck in Pending. Walk me through it. (09)
- CrashLoopBackOff. Walk me through it. (09)
- Service returns connection refused. Walk me through it. (09)
- Deployment rollout stuck at 1/3. Why? (02, 09)

**Architecture**
- Name the control plane components and what each does. (00)
- What is etcd and why does the cluster die without it? (00)
- What does the kubelet do? What does kube-proxy do? (00, 03)
- How does a container runtime relate to Kubernetes? (00)
