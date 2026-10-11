# 05. Storage

Goal: give a pod a disk that outlives it. PVC, PV, StorageClass, StatefulSet. Understand why `Pending` on a PVC is often fine.

## Concept

Three objects, in the order a request flows:

```
Pod --mounts--> PersistentVolumeClaim --binds--> PersistentVolume
                    "I need 1Gi RWO"             actual disk (EBS, NFS, local dir)
                          |
                    StorageClass: who provisions PVs on demand and how
```

You write the PVC (the ask). The StorageClass's provisioner creates a PV (the disk) and binds them. The pod mounts the PVC by name. Delete the pod, the PVC and data stay. Delete the PVC, the reclaim policy decides if the PV is deleted or retained.

ECS analogy: EFS volume in a task definition, but with on-demand provisioning and a lifecycle of its own.

Here the class is `local-path`: a directory under `/var/lib/kubesolo` on the node. Reclaim policy `Retain`, binding mode `WaitForFirstConsumer`, which means a PVC stays `Pending` until a pod uses it. On EKS the class would be `gp3` backed by EBS, `WaitForFirstConsumer` there ensures the EBS volume lands in the same availability zone as the pod.

Access modes: `ReadWriteOnce` (one node), `ReadOnlyMany`, `ReadWriteMany` (needs NFS or EFS class). EBS and local-path are RWO only.

**StatefulSet** vs Deployment: stable names (`db-0`, `db-1`), one PVC per pod created from a template, ordered start and stop, a headless Service so each pod has its own DNS name. Databases, queues, anything where pod identity matters. Deployments share one PVC across all replicas, which is wrong for a database.

## Walkthrough

### The Pending PVC

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: scratch
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
EOF
kubectl get pvc scratch
kubectl describe pvc scratch | tail -4
```

PREDICT: STATUS?

`Pending`, with an event "waiting for first consumer to be created before binding". Not a bug. Attach a pod:

```sh
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: writer
spec:
  containers:
    - name: w
      image: busybox:1.36
      command: [sh, -c, "echo written-by-$HOSTNAME-at-$(date +%s) >> /data/log; sleep infinity"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: scratch
EOF
kubectl get pvc,pv
kubectl exec writer -- cat /data/log
```

Bound now, a PV appeared. Look where it lives:

```sh
kubectl get pv -o jsonpath='{.items[0].spec.local.path}{"\n"}'
orb -m kubesolo sudo ls -la $(kubectl get pv -o jsonpath='{.items[0].spec.local.path}')
```

### Data survives the pod

PREDICT: after delete and recreate, how many lines in `/data/log`?

```sh
kubectl delete pod writer
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: writer
spec:
  containers:
    - name: w
      image: busybox:1.36
      command: [sh, -c, "echo written-by-$HOSTNAME-at-$(date +%s) >> /data/log; sleep infinity"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: scratch
EOF
kubectl exec writer -- cat /data/log
```

Two lines. Now delete the PVC:

```sh
kubectl delete pod writer
kubectl delete pvc scratch
kubectl get pv                # still there: Released, policy Retain
```

The PV outlived the claim. With `Delete` policy (the default on cloud classes) it would be gone. Clean the orphan: `kubectl delete pv --all`.

### emptyDir, the other volume

Not persistent. Lives as long as the pod, shared between its containers. Scratch space and sidecar handoff.

```yaml
volumes:
  - name: tmp
    emptyDir: {}
```

### StatefulSet with Postgres

Read `postgres.yaml`. Note `volumeClaimTemplates`, `serviceName`, and the headless Service.

```sh
kubectl apply -f postgres.yaml
kubectl get sts,pods,pvc -l app=db -w      # ctrl-c when db-0 is Running
kubectl exec db-0 -- psql -U app -c "create table t(v text); insert into t values ('hello');"
```

PREDICT: after deleting `db-0`, what is the new pod called, and is the row still there?

```sh
kubectl delete pod db-0
kubectl get pods -l app=db -w              # ctrl-c when Running again
kubectl exec db-0 -- psql -U app -c "select * from t;"
```

Same name, same PVC `data-db-0`, same data. DNS for the pod:

```sh
kubectl run tmp --image=busybox:1.36 --restart=Never --rm -it -- nslookup db-0.db.default.svc.cluster.local
```

Scale to 2 and see the ordered creation and per-pod PVCs:

```sh
kubectl scale sts db --replicas=2
kubectl get pods,pvc -l app=db
```

`db-1` has its own empty database. StatefulSet gives identity and storage, replication is the application's job.

## Checkpoint

```sh
kubectl get pvc data-db-0 -o jsonpath='{.status.phase}'    # Bound
kubectl exec db-0 -- psql -U app -tAc "select count(*) from t;"   # 1
```

## Quiz

1. PVC is `Pending`. Give two innocent causes and one real problem.
2. What decides whether a PV is deleted when its PVC is deleted?
3. Two replicas of a Deployment mount the same RWO PVC. What happens?
4. Why does a StatefulSet want a headless Service?
5. You delete a StatefulSet. What happens to its PVCs?
6. Interview: "Would you run Postgres on Kubernetes?"

<details>
<summary>Answers</summary>

1. Innocent: `WaitForFirstConsumer` with no pod yet, or the provisioner is still creating the disk. Problem: no StorageClass matches (`storageClassName` typo or no default class), requested access mode not supported by the class, or quota exceeded. `describe pvc` events tell you which.
2. `persistentVolumeReclaimPolicy` on the PV, inherited from the StorageClass's `reclaimPolicy` at provisioning time. `Delete` removes the disk, `Retain` leaves it `Released` for manual recovery.
3. On one node it works, both pods share the directory, likely data corruption for a database. On different nodes the second pod stays `ContainerCreating` because the volume can attach to one node only. Use `ReadWriteMany` storage or one PVC per replica via StatefulSet.
4. Stable per-pod DNS: `db-0.db.ns.svc.cluster.local`. A normal Service would load balance across replicas, which is wrong when clients need the primary specifically.
5. Nothing. PVCs from `volumeClaimTemplates` are kept so data survives an accidental delete. Delete them by hand, or set `persistentVolumeClaimRetentionPolicy` on newer clusters.
6. It depends on the team. Yes with an operator (CloudNativePG, Zalando) that handles replication, failover, backups, and a storage class with real durability. For a small team on AWS, RDS is less risk. Show you know the trade-off: operational burden versus portability and cost.
</details>

## Task

From scratch, deploy Redis with persistence:

- StatefulSet `cache`, 1 replica, image `redis:7-alpine`, args `--appendonly yes`, container port 6379, labels `app: cache`
- `volumeClaimTemplates` named `data`, 200Mi, RWO, mounted at `/data`
- headless Service `cache` on port 6379

Write a key, delete the pod, read it back:

```sh
kubectl exec cache-0 -- redis-cli set lesson 05
kubectl delete pod cache-0 && kubectl wait --for=condition=Ready pod/cache-0 --timeout=120s
kubectl exec cache-0 -- redis-cli get lesson     # "05"
./check.sh
```

Clean up: `kubectl delete -f postgres.yaml; kubectl delete sts cache svc cache; kubectl delete pvc --all; kubectl delete pv --all`.
