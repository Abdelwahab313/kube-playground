# 07. Helm and Kustomize

Goal: stop copy-pasting YAML between environments. Install public charts, package your own, and patch a base for dev and prod.

## Concept

Both solve "same app, different environments" but differently:

| | Helm | Kustomize |
|---|---|---|
| Model | Templates (Go text/template) rendered with values | Plain YAML base plus overlays that patch it |
| Packaging | Charts, versioned, in registries | Directories in git |
| State | Tracks releases in the cluster (Secrets) | None, `kubectl apply -k` |
| Good at | Third-party software, complex conditionals | Your own apps, readable diffs |
| Pain | Templates hard to read, `{{ toYaml | nindent }}` | No loops, patch syntax for edge cases |
| Built in | Separate binary | `kubectl -k` |

ECS analogy: Helm is closest to a CloudFormation or Terraform module for a task definition. Kustomize is closer to `docker-compose.override.yml`.

Most k8s-heavy companies use Helm for vendor software (ingress-nginx, Prometheus, Argo CD) and Kustomize or Helm for their own apps, driven by Argo CD or Flux. Know both.

## Walkthrough

### Helm: install something public

You did this in lesson 03. Now look at what you did.

```sh
helm list -A
helm -n ingress-nginx get values ingress-nginx      # what you set (nothing)
helm -n ingress-nginx get values ingress-nginx --all | head -40   # defaults
helm -n ingress-nginx get manifest ingress-nginx | grep -c '^kind:'   # objects it created
helm -n ingress-nginx history ingress-nginx
```

Change one value and upgrade:

```sh
helm upgrade ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx \
  --reuse-values --set controller.replicaCount=2
kubectl -n ingress-nginx get pods
helm -n ingress-nginx history ingress-nginx
helm -n ingress-nginx rollback ingress-nginx 1
```

Always render before you install anything new:

```sh
helm template demo-redis oci://registry-1.docker.io/bitnamicharts/redis --set architecture=standalone --set auth.enabled=false | less
```

### Helm: write a chart

```sh
helm create webapp
tree webapp
```

Read `webapp/templates/deployment.yaml` and `webapp/values.yaml` side by side. Every `{{ .Values.x }}` is a value, `{{ include "webapp.fullname" . }}` is a helper from `_helpers.tpl`.

Edit `values.yaml`: `image.repository: nginx`, `image.tag: "1.27-alpine"`, `service.port: 80`. Then:

```sh
helm template webapp ./webapp | less                # render locally
helm lint ./webapp
helm install webapp ./webapp
helm status webapp
kubectl get all -l app.kubernetes.io/instance=webapp
```

Add the config-hash trick from lesson 04. In `templates/deployment.yaml` under `spec.template.metadata`:

```yaml
      annotations:
        checksum/config: {{ toYaml .Values.config | sha256sum }}
```

and a `config:` map in values. Change a value, `helm upgrade webapp ./webapp`, watch pods roll.

### Kustomize: base and overlays

```
kustomize/
  base/                 deployment + service + kustomization.yaml
  overlays/dev/         1 replica, debug env, name prefix dev-
  overlays/prod/        3 replicas, resource limits, name prefix prod-
```

```sh
kubectl kustomize kustomize/overlays/dev | less
kubectl kustomize kustomize/overlays/prod | less
diff <(kubectl kustomize kustomize/overlays/dev) <(kubectl kustomize kustomize/overlays/prod)
kubectl apply -k kustomize/overlays/dev
kubectl apply -k kustomize/overlays/prod
kubectl get deploy
```

Both from one base, both in the cluster, distinguished by prefix. Note the ConfigMap name in the output has a hash suffix. Change `LOG_LEVEL` in `overlays/dev/kustomization.yaml`, render again, see the new hash and the Deployment referencing it. That is Kustomize's answer to config rollouts.

Add a patch. In `overlays/prod/kustomization.yaml` there is a strategic merge patch setting resources. Add an inline JSON patch to change the image tag:

```yaml
patches:
  - target:
      kind: Deployment
      name: web
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: nginx:1.28-alpine
```

Render, apply, confirm.

### Diff before apply

```sh
kubectl diff -k kustomize/overlays/prod
helm diff upgrade webapp ./webapp      # needs: helm plugin install https://github.com/databus23/helm-diff
```

Teams that run GitOps see this diff in every PR. Get used to reading it.

## Checkpoint

```sh
helm list
kubectl get deploy dev-web prod-web
```

## Quiz

1. Where does Helm store release state? What breaks if you `kubectl delete` those objects?
2. `helm upgrade --set x=1` then `helm upgrade --set y=2`. Is `x` still set? What flag changes that?
3. Kustomize `configMapGenerator` gives the ConfigMap a hashed name. Why is that good, and what does it cost you?
4. You need one Deployment in dev and three in prod, and prod also gets a sidecar. Helm or Kustomize, and how?
5. A colleague ran `helm install` with `--set image.tag=latest` in prod. What is the argument against, beyond "latest is bad"?
6. Interview: "Helm or Kustomize, and why?"

<details>
<summary>Answers</summary>

1. Secrets named `sh.helm.release.v1.<name>.v<n>` in the release namespace. Delete them and Helm forgets the release: `helm list` is empty, `helm upgrade` fails with "has no deployed releases" while the workloads still run. Recovery is `helm install` again with the same name, or restoring the Secret.
2. No. Each `upgrade` starts from chart defaults unless you pass `--reuse-values` (previous values plus your new sets) or provide a values file with everything. Values files in git, not `--set`, avoid the problem.
3. Any content change is a name change, so every referencing Deployment template changes and rolls, and old pods keep the old ConfigMap until they die. Cost: the name is unpredictable, you cannot reference it from outside the kustomization, and old ConfigMaps accumulate (prune with `kubectl apply --prune` or GitOps tooling).
4. Either. Kustomize: overlays with a replicas patch and a strategic merge patch adding the container. Helm: `replicaCount` value and `{{ if .Values.sidecar.enabled }}` block. Kustomize reads cleaner for own apps, Helm if it is already a chart.
5. Kubernetes only pulls when the image reference changes (or `imagePullPolicy: Always`). `latest` twice is a no-op deploy, and different nodes may have cached different `latest`. You lose the ability to see what is running and to roll back. Use immutable tags or digests.
6. Both, by role. Helm for third-party charts and when you need real templating. Kustomize for your own manifests because the base is valid YAML anyone can read, patches are small and reviewable, and it needs no extra state. Under Argo CD or Flux both are first class, so the choice is about readability and team familiarity.
</details>

## Task

Package the lesson 03 app (frontend, backend, ingress) as a Helm chart named `shop` in this directory, with values for:

- `backend.replicas` (default 2), `backend.image`
- `frontend.replicas` (default 1), `frontend.image`
- `ingress.host` (default `shop.local`)

Install it as release `shop` with `frontend.replicas=2` and `ingress.host=shop.test`. Then `./check.sh`.

Clean up: `helm uninstall shop webapp; kubectl delete -k kustomize/overlays/dev; kubectl delete -k kustomize/overlays/prod`.
