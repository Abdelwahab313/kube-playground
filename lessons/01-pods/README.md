# 01. Pods and kubectl

Goal: run, inspect, exec into, and kill pods. Read a pod YAML and know what every line does.

## Concept

A Pod is the smallest thing Kubernetes schedules. It is one or more containers that share a network namespace (same IP, talk over `localhost`) and can share volumes. Almost always one container. The ECS analogy is a running task, but with one big difference:

**A bare pod is not restarted anywhere else if its node dies, and is not recreated if you delete it.** ECS services and Kubernetes Deployments do that. Pods are the unit, not the manager.

`kubectl` is a REST client. Every command reads or writes an object on the API server. The object you send is the desired state. The cluster's controllers work to make reality match. `status:` in the YAML is reality, written by the cluster.

## Walkthrough

### Imperative first

```sh
kubectl run web --image=nginx:1.27-alpine
kubectl get pods
kubectl get pods -o wide            # IP and node
kubectl describe pod web            # read Events at the bottom
```

PREDICT: how many containers in the pod? What is the restart policy? Check with:

```sh
kubectl get pod web -o yaml | less
```

Find `spec.containers`, `spec.restartPolicy`, `status.phase`, `status.podIP`, `status.containerStatuses`.

### Talk to it

```sh
kubectl logs web
kubectl exec -it web -- sh
# inside: hostname; ip addr; wget -qO- localhost; exit
kubectl port-forward pod/web 8080:80
# other terminal: curl localhost:8080
```

### Kill it

PREDICT: what does `kubectl get pods` show 10 seconds after this?

```sh
kubectl exec web -- kill 1
kubectl get pods -w        # ctrl-c after a change
kubectl describe pod web | grep -A3 "Last State"
```

The container restarted (RESTARTS went to 1) because `restartPolicy: Always` and the kubelet restarts containers inside a pod. The pod itself never left.

PREDICT: and after this?

```sh
kubectl delete pod web
kubectl get pods
```

Gone for good. Nothing owned it.

### Declarative

Look at `pod.yaml` in this directory, then:

```sh
kubectl apply -f pod.yaml
kubectl get pod web -o yaml | head -40    # compare with the file, note what the cluster added
kubectl apply -f pod.yaml                 # PREDICT: what does it print the second time?
```

`apply` is idempotent. Run it a hundred times, same result. That is the whole model: you own the file, the cluster owns the diff.

### Multi-container pod

Edit `pod.yaml`, add a second container under `containers:`:

```yaml
      - name: sidecar
        image: busybox:1.36
        command: [sh, -c, "while true; do wget -qO- localhost >/dev/null && echo ok || echo fail; sleep 5; done"]
```

PREDICT: will `kubectl apply` succeed on a running pod when you add a container?

```sh
kubectl apply -f pod.yaml
```

Most pod spec fields are immutable. You get `Forbidden: pod updates may not add or remove containers`. Delete and recreate. Deployments handle this for you in lesson 02, which is the real reason they exist.

```sh
kubectl delete -f pod.yaml && kubectl apply -f pod.yaml
kubectl logs web -c sidecar -f     # ctrl-c
```

The sidecar reaches nginx on `localhost`. Same network namespace.

### Labels

Labels are how everything finds everything in Kubernetes. Services, Deployments, and your own queries select by label.

```sh
kubectl get pods --show-labels
kubectl label pod web tier=frontend
kubectl get pods -l tier=frontend
kubectl get pods -l tier=backend      # empty
```

## Checkpoint

```sh
kubectl get pod web -o jsonpath='{.spec.containers[*].name}'   # web sidecar
kubectl get pod web -o jsonpath='{.metadata.labels.tier}'      # frontend
```

## Quiz

1. Two containers in one pod. Can they reach each other on `localhost`? Can they see each other's filesystem?
2. You delete a pod created with `kubectl run`. Does it come back? Why or why not?
3. What is the difference between `kubectl create -f` and `kubectl apply -f`?
4. A pod shows `RESTARTS 5`. Did the pod restart, or something else?
5. What does `kubectl describe pod` show you that `kubectl get pod -o yaml` does not?
6. Interview: "What is a Pod and why not just schedule containers?"

<details>
<summary>Answers</summary>

1. Yes on localhost, they share the network namespace. No on filesystem by default, each container has its own root filesystem. Share files with a volume mounted in both.
2. No. Nothing owns a bare pod. Only a controller (ReplicaSet, Job, DaemonSet, StatefulSet) recreates pods.
3. `create` fails if the object exists. `apply` creates or patches to match the file and records the last applied config in an annotation so it can compute three-way diffs. Use `apply` for everything you keep in files.
4. Containers inside the pod restarted. The pod object kept its name, IP and UID. A pod being replaced would have a new name.
5. Events. Scheduling decisions, image pulls, probe failures, OOM kills. Events are separate objects, `describe` joins them for you. `kubectl get events` shows them raw.
6. A Pod groups containers that must be co-located and co-scheduled: they share IP, port space, IPC, and can share volumes. It gives you the sidecar pattern (log shipper, proxy, init container) with one scheduling decision. Scheduling single containers would make those patterns impossible to express atomically.
</details>

## Task

Without looking at `pod.yaml`, write `task.yaml` from scratch that creates a pod named `task-pod` with:

- label `lesson: "01"`
- a container `app` running `nginx:1.27-alpine`
- a container `logger` running `busybox:1.36` that prints the date every 10 seconds
- an environment variable `GREETING=hello` on the `app` container

Then:

```sh
kubectl apply -f task.yaml
./check.sh
```

Do not delete it until the check passes. Then clean up:

```sh
kubectl delete pod web task-pod
```
