# 08. Real app project

Goal: port a Compose-style stack to Kubernetes end to end, with the production pieces that interviews ask about: Jobs, CronJobs, HPA, PDB, init containers, graceful shutdown. No step-by-step. You have lessons 01 to 07 and `REFERENCE.md`.

Budget: one week of evenings. Commit as you go.

## The stack

Pick an app you already have as a Compose file, or use this one:

```
api        HTTP service, reads and writes Postgres, caches in Redis
worker     consumes a queue (Redis list), writes results to Postgres
postgres   StatefulSet with persistence
redis      StatefulSet with persistence
migrate    one-shot Job that runs schema migrations before api starts
report     CronJob every 5 minutes that counts rows and logs the number
```

If you do not want to write code, use these images:

- api and worker: `ghcr.io/mendhak/http-https-echo:34` as a stand-in for api, `busybox` loops for the worker. The point is the Kubernetes objects, not the app.
- Better: a 50-line Flask, FastAPI, Express or Go app that you push to `ghcr.io/<you>/api`. Then you also learn `imagePullSecrets`.

## Milestones

Each milestone is a commit in `lessons/08-real-app/manifests/` (or a Helm chart, or a Kustomize base with overlays). Tick them in order.

### M1. Namespace and data layer

- [ ] Namespace `shop`
- [ ] Postgres StatefulSet, headless Service, PVC, credentials in a Secret
- [ ] Redis StatefulSet with `--appendonly yes`, headless Service
- [ ] Both have readiness probes (`pg_isready`, `redis-cli ping`)
- [ ] Resource requests and limits on everything

Check: `kubectl -n shop get sts,pvc,svc` all Bound and Ready.

### M2. Migration Job and init container

- [ ] Job `migrate` that creates the schema. `restartPolicy: OnFailure`, `backoffLimit: 3`, `ttlSecondsAfterFinished: 600`
- [ ] api Deployment has an `initContainer` that waits for Postgres to accept connections before the main container starts
- [ ] api reads DB credentials from the Secret, config from a ConfigMap, with the config-hash annotation

Check: `kubectl -n shop get job migrate` shows `1/1` completions. Delete the Postgres pod, watch api's init container hold new api pods until it is back.

### M3. Expose it

- [ ] ClusterIP Service for api
- [ ] Ingress on `shop.local` through ingress-nginx
- [ ] `curl -H "Host: shop.local" http://$NODE_IP/healthz` returns 200

### M4. Worker and CronJob

- [ ] worker Deployment, 2 replicas, consumes from Redis
- [ ] CronJob `report` every 5 minutes, `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`
- [ ] Trigger one manually: `kubectl -n shop create job report-now --from=cronjob/report`

Check: `kubectl -n shop get cj,job` shows scheduled runs and their pods `Completed`.

### M5. Autoscaling and availability

- [ ] HorizontalPodAutoscaler on api: min 2, max 6, target 50% CPU. Requires CPU requests on the api container and metrics-server (installed in lesson 00)
- [ ] Generate load and watch it scale:

  ```sh
  kubectl -n shop run load --image=busybox:1.36 --restart=Never --rm -it -- \
    sh -c 'while true; do wget -qO- http://api/ >/dev/null; done'
  kubectl -n shop get hpa -w
  ```

- [ ] PodDisruptionBudget on api with `minAvailable: 1`
- [ ] `terminationGracePeriodSeconds` and a `preStop` hook on api so in-flight requests finish during rollouts
- [ ] Rolling update with `maxUnavailable: 0` while `curl` runs in a loop. Zero failed requests.

Check: `kubectl -n shop get hpa,pdb`. During a `rollout restart` of api, a `while true; do curl -sf ... || echo FAIL; done` loop prints no FAIL.

### M6. Package and diff

- [ ] Everything as a Helm chart or Kustomize base with `dev` and `prod` overlays (prod: 3 api replicas, higher limits, `LOG_LEVEL=warn`)
- [ ] `kubectl diff -k overlays/prod` or `helm diff` shows a clean change when you bump the api image tag
- [ ] README in `manifests/` explaining how to install from zero on a fresh cluster

### M7. Break it on purpose

Do each, fix each, write one line on what the symptom was:

- [ ] Wrong DB password in the Secret
- [ ] Postgres PVC full (`fallocate` a big file inside the volume)
- [ ] api memory limit set to 20Mi
- [ ] Ingress pointing at a Service port that does not exist
- [ ] HPA with no CPU request on the container
- [ ] CronJob schedule `* * * * *` with a Job that takes 2 minutes and `concurrencyPolicy: Allow`

## Quiz

1. What is the difference between an init container and a readiness probe for "wait for the database"?
2. Job with `backoffLimit: 3` and `restartPolicy: OnFailure` versus `Never`. How many pods do you see after 3 failures in each case?
3. HPA shows `<unknown>/50%`. Three causes.
4. A PDB with `minAvailable: 1` on a 1-replica Deployment. What happens during `kubectl drain`?
5. Rolling update drops a few requests. Name three settings that fix it.
6. Interview: "How would you run a database migration as part of a deploy?"

<details>
<summary>Answers</summary>

1. Init container blocks the pod from starting its main containers at all, runs once. Readiness gates traffic but the app is already running and may crash on a failed DB connection. Use init for hard dependencies at boot, readiness for ongoing health.
2. `OnFailure`: one pod, restarted 3 times in place, RESTARTS 3. `Never`: a new pod per attempt, 4 pods in Error, useful because each has its own logs.
3. metrics-server not installed or not healthy. The container has no `resources.requests.cpu`, so percentage cannot be computed. Pods too young, metrics not collected yet.
4. Drain blocks forever, the pod cannot be evicted without violating the budget. Correct behavior. Either scale to 2 first or accept downtime with `--disable-eviction`. Never set a PDB that can never be satisfied.
5. `maxUnavailable: 0` so old pods leave only after new ones are Ready. Readiness probe that only passes when the app can serve. `preStop` sleep of a few seconds plus `terminationGracePeriodSeconds` longer than the longest request, so the pod drains after being removed from endpoints. The app handling SIGTERM gracefully.
6. Kubernetes Job run before the rollout, in CI or as a Helm pre-upgrade hook or Argo CD PreSync hook. Migrations must be backward compatible with the currently running version because old and new pods overlap during the roll. Idempotent, with a lock so two runs do not race. Never in an init container of the api, that races across replicas.
</details>

## Check

There is no `check.sh` for this lesson. Your check is: delete the namespace, reinstall from your chart or overlay in one command, and everything comes back Ready with the data gone but the schema present after the migration Job. Time it. Under two minutes is good.
