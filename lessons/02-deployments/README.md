# 02. Deployments

Goal: replicas that heal, rolling updates, rollbacks, probes. This is the ECS service equivalent and the most interviewed topic.

## Concept

Three objects, three jobs:

```
Deployment      "I want 3 replicas of template T, roll changes out gradually"
  └── ReplicaSet   "keep exactly N pods matching selector S alive"
        └── Pod × N
```

You write the Deployment. The deployment controller creates a ReplicaSet per template version. The ReplicaSet controller creates and replaces pods. Change the template, and the Deployment creates a new ReplicaSet, scales it up while scaling the old one down. Rollback means scale the old one back up.

ECS mapping: Deployment is the service, ReplicaSet is roughly a task set during a deployment, `minimumHealthyPercent` and `maximumPercent` are `maxUnavailable` and `maxSurge`.

Probes are the health checks ECS gets from the target group, but per container and richer:

- **readiness**: failing means take me out of Service endpoints, do not restart me. Use for "not ready yet" and "overloaded".
- **liveness**: failing means kill and restart the container. Use for "deadlocked".
- **startup**: gates the other two until it passes. Use for slow-starting apps so liveness does not kill them mid-boot.

## Walkthrough

### Self-healing

```sh
kubectl apply -f deployment.yaml
kubectl get deploy,rs,pods
```

Note the names: `web`, `web-<hash>`, `web-<hash>-<random>`. The hash is of the pod template.

PREDICT: you delete one pod. How long until there are 3 again? Which name changes?

```sh
kubectl delete pod -l app=web --wait=false; kubectl get pods -w
```

Now scale:

```sh
kubectl scale deploy web --replicas=5
kubectl get pods
kubectl scale deploy web --replicas=3
```

`scale` edits `spec.replicas` on the live object. Your file still says 3. This is drift. In real teams, you change the file and `apply`. Imperative commands are for experiments and incidents.

### Rolling update

Open a second terminal and watch:

```sh
kubectl get pods -w
```

In the first:

```sh
kubectl set image deploy/web web=nginx:1.28-alpine
kubectl rollout status deploy/web
kubectl get rs                       # two ReplicaSets now, old one at 0
kubectl rollout history deploy/web
```

PREDICT: with `maxSurge: 1` and `maxUnavailable: 0`, what was the max and min pod count during the roll?

### Break the rollout

```sh
kubectl set image deploy/web web=nginx:does-not-exist
kubectl rollout status deploy/web --timeout=30s
kubectl get pods
kubectl get deploy web
```

`ImagePullBackOff` on one new pod, old three still serving. `maxUnavailable: 0` protected you. Look at the columns of `kubectl get deploy`: READY 3/3, UP-TO-DATE 1, AVAILABLE 3. Learn to read these.

```sh
kubectl rollout undo deploy/web
kubectl rollout status deploy/web
kubectl rollout history deploy/web
```

### Probes

Edit `deployment.yaml`. Change the readiness probe path to `/nope`. Apply.

PREDICT: do the old pods get replaced? Does the site go down?

```sh
kubectl apply -f deployment.yaml
kubectl get pods
kubectl describe pod -l app=web | grep -A2 Readiness | head
```

New pods sit at `0/1 READY`, rollout stalls, old pods keep serving. That is readiness doing its job. Revert the path, apply again.

Now break liveness instead: path `/nope` on `livenessProbe`. Apply, wait a minute.

```sh
kubectl get pods    # RESTARTS climbing on new pods
```

Liveness kills. Revert.

### Annotate your history

```sh
kubectl annotate deploy/web kubernetes.io/change-cause="bump nginx to 1.28"
kubectl rollout history deploy/web
```

## Checkpoint

```sh
kubectl get deploy web -o jsonpath='{.status.readyReplicas}'   # 3
kubectl get rs -l app=web --no-headers | wc -l                  # 2 or more, only one non-zero
```

## Quiz

1. You change `replicas` from 3 to 5 in the file and apply. Is a new ReplicaSet created?
2. You change the image tag. Is a new ReplicaSet created?
3. `maxSurge: 25%`, `maxUnavailable: 25%`, 4 replicas. Max pods during a rollout? Min ready?
4. A pod's readiness probe fails. What happens to the pod? To the Service?
5. A pod's liveness probe fails 3 times. What happens?
6. Your app takes 90 seconds to boot. Liveness has `initialDelaySeconds: 10`. What happens, and what is the right fix?
7. Interview: "Walk me through what happens when you run `kubectl apply` on a Deployment with a new image."

<details>
<summary>Answers</summary>

1. No. Only pod template changes create a new ReplicaSet. Replicas just scales the current one.
2. Yes. The template hash changes, a new ReplicaSet is created and the rollout begins.
3. Max 5 (4 + 25% surge = 1 extra). Min ready 3 (4 minus 25% unavailable = 1 down).
4. Pod stays running, is removed from the Service's endpoints so it gets no traffic. Nothing restarts it.
5. kubelet kills the container and restarts it, backing off exponentially on repeat failures. RESTARTS goes up, pod name stays the same.
6. Liveness starts failing at 10s, kills the container, it never finishes booting: crash loop caused by the probe. Fix with a `startupProbe` with `failureThreshold * periodSeconds` greater than 90s. Raising `initialDelaySeconds` also works but is a guess.
7. apiserver validates and stores the new Deployment spec. Deployment controller sees the template changed, computes a new hash, creates a new ReplicaSet with 0 replicas, then scales it up and the old one down respecting maxSurge and maxUnavailable. ReplicaSet controller creates pods. Scheduler assigns them nodes. kubelet pulls the image, starts containers, runs probes. When a new pod is Ready, endpoints controller adds it to Services, and the Deployment controller continues. Old ReplicaSet kept at 0 for rollback, up to `revisionHistoryLimit`.
</details>

## Task

Write `task.yaml` from memory: a Deployment `api` with

- 3 replicas, labels `app: api`
- image `nginxinc/nginx-unprivileged:1.27-alpine` listening on 8080 (unprivileged nginx, port 8080)
- readiness probe: HTTP GET `/` on 8080 every 5 seconds
- liveness probe: HTTP GET `/` on 8080, initial delay 10 seconds
- rolling update with `maxSurge: 1`, `maxUnavailable: 0`
- resources: request 50m CPU, 32Mi memory

Then perform one image update to `nginxinc/nginx-unprivileged:1.28-alpine` and record a change-cause annotation, so that `rollout history` shows two revisions.

```sh
kubectl apply -f task.yaml
kubectl set image deploy/api api=nginxinc/nginx-unprivileged:1.28-alpine
kubectl annotate deploy/api kubernetes.io/change-cause="upgrade to 1.28"
./check.sh
```

Clean up: `kubectl delete deploy web api`.
