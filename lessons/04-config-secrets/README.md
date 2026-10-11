# 04. Config and Secrets

Goal: separate config from images the Kubernetes way, know the difference between env injection and file mounts, and roll pods when config changes.

## Concept

**ConfigMap**: key-value pairs, or whole files, stored as an object. **Secret**: same thing, base64 encoded, with slightly different handling (not logged by kubectl, can be encrypted at rest if the cluster is configured for it, mounted as tmpfs). Base64 is not encryption. Anyone who can read the Secret object can read the value.

ECS analogy: `environment` and `secrets` in the task definition, with SSM or Secrets Manager behind them. Difference: in Kubernetes the values live in the cluster itself, unless you add an external-secrets operator.

Two ways in:

| Method | Updates live? | Use when |
|---|---|---|
| env var (`env`, `envFrom`) | No. Pod must restart | 12-factor apps, simple values |
| volume mount | Yes, eventually (kubelet sync, about a minute), unless `subPath` | Config files, certs, anything the app re-reads |

Pods do not restart when a ConfigMap changes. You have to make them. The common trick is a hash of the config in a pod template annotation, so a config change is a template change and triggers a rollout. Helm and Kustomize automate this.

## Walkthrough

### Create both ways

```sh
kubectl create configmap app-cfg --from-literal=LOG_LEVEL=info --from-literal=FEATURE_X=true
kubectl create secret generic app-secret --from-literal=DB_PASSWORD='s3cr3t'
kubectl get cm app-cfg -o yaml
kubectl get secret app-secret -o yaml
echo czNjcjN0 | base64 -d      # the "encryption"
```

Same objects from a file. Read `config.yaml`, it defines the ConfigMap and a Deployment consuming it three ways.

```sh
kubectl delete cm app-cfg
kubectl apply -f config.yaml
kubectl get pods -l app=cfg-demo
```

### See the three injection styles

```sh
POD=$(kubectl get pod -l app=cfg-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- env | grep -E 'LOG_LEVEL|FEATURE_X|DB_PASSWORD|GREETING'
kubectl exec $POD -- ls -la /etc/app
kubectl exec $POD -- cat /etc/app/settings.ini
```

Note `/etc/app/settings.ini` is a symlink into a `..data` directory. That is how the kubelet swaps whole directories atomically on update.

### Live update, or not

Change `LOG_LEVEL` to `debug` and the ini file content in `config.yaml`. Apply.

PREDICT: which of these changes inside the running pod within two minutes: the env var, the mounted file?

```sh
kubectl apply -f config.yaml
sleep 70
kubectl exec $POD -- env | grep LOG_LEVEL
kubectl exec $POD -- cat /etc/app/settings.ini
```

File updated, env did not. Same pod, same name, no restart.

### Force the rollout

```sh
kubectl rollout restart deploy/cfg-demo
kubectl get pods -l app=cfg-demo
POD=$(kubectl get pod -l app=cfg-demo -o jsonpath='{.items[0].metadata.name}')
kubectl exec $POD -- env | grep LOG_LEVEL
```

`rollout restart` adds an annotation with a timestamp to the template, which counts as a change. Now do it declaratively: add to the pod template in `config.yaml`:

```yaml
      annotations:
        config-hash: "v2"
```

Bump the value each time config changes. Apply and watch the roll. Helm does `checksum/config: {{ .Files.Get "config.ini" | sha256sum }}`, Kustomize's `configMapGenerator` appends a hash to the name instead. Both are the same idea.

### Missing reference

Edit the Deployment env to reference key `DOES_NOT_EXIST` in the ConfigMap. Apply.

```sh
kubectl get pods -l app=cfg-demo        # CreateContainerConfigError on the new pod
kubectl describe pod -l app=cfg-demo | grep -A3 Warning
```

Fix it. This status is the tell for "env references something that is not there". Add `optional: true` on the ref if the key really is optional.

### Immutable

```yaml
immutable: true
```

on a ConfigMap or Secret means no edits, delete and recreate only. Used with generated names for safety and performance in large clusters.

## Checkpoint

```sh
kubectl get cm,secret
kubectl exec deploy/cfg-demo -- cat /etc/app/settings.ini
```

## Quiz

1. You edit a ConfigMap used as env vars. What do running pods see?
2. You edit a ConfigMap mounted as a volume with `subPath`. What do running pods see?
3. Is a Secret safer than a ConfigMap? In what ways, concretely?
4. How do you make pods restart when their config changes, in a declarative way?
5. A pod is stuck in `CreateContainerConfigError`. Most likely cause?
6. Interview: "How would you handle database credentials for an app on Kubernetes at a company that already uses AWS Secrets Manager?"

<details>
<summary>Answers</summary>

1. Nothing. Env is read once at container start. They need a restart.
2. Nothing. `subPath` mounts copy the file once and never update. Mount the whole directory if you want live updates.
3. Marginally. Not printed by `kubectl describe pod` in env listings, stored in tmpfs when mounted, can be encrypted at rest with an EncryptionConfiguration on the apiserver, and RBAC lets you grant read on ConfigMaps without Secrets. But base64 in etcd is plaintext for anyone with etcd or `get secret` access.
4. Put a hash or version of the config in a pod template annotation. Changing config changes the template, Deployment rolls. Kustomize configMapGenerator does it with hashed names, Helm with a checksum annotation, Reloader operator does it automatically.
5. A `configMapKeyRef` or `secretKeyRef` points at a missing object or key, or a mounted ConfigMap/Secret does not exist. Events say exactly which.
6. Do not copy them into Kubernetes Secrets by hand. Run External Secrets Operator or the Secrets Store CSI Driver with the AWS provider, IRSA (IAM Roles for Service Accounts) on the pod's ServiceAccount for auth, sync into a Secret or mount as files, rotate at the source. Mention encryption at rest and RBAC on the Secret namespace.
</details>

## Task

From scratch:

- ConfigMap `task-cfg` with keys `MODE=prod` and a file key `nginx.conf` containing a minimal nginx config that serves `/healthz` returning 200 with body `ok` on port 8080
- Secret `task-secret` with key `API_KEY` = `abc123`
- Deployment `task-web`, 1 replica, image `nginx:1.27-alpine`, with:
  - `MODE` from the ConfigMap as an env var
  - `API_KEY` from the Secret as an env var
  - the ConfigMap's `nginx.conf` mounted at `/etc/nginx/nginx.conf` using `subPath`
  - pod template annotation `config-hash` set to any value

Hint for the nginx config:

```
events {}
http {
  server {
    listen 8080;
    location /healthz { return 200 'ok'; }
  }
}
```

Verify with `kubectl exec deploy/task-web -- wget -qO- localhost:8080/healthz` then `./check.sh`.

Clean up: `kubectl delete -f config.yaml; kubectl delete deploy task-web cm task-cfg secret task-secret app-secret`.
