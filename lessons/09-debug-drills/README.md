# 09. Debug drills

Goal: fix broken manifests fast, using only `kubectl`. This is what technical interviews and on-call actually look like.

## Rules

1. Apply one drill. Start a timer.
2. Diagnose with `kubectl get`, `describe`, `logs`, `events`, `exec`. Do not read the YAML file first. Reading the YAML is cheating, in real life the YAML is 2000 lines in a Helm chart.
3. Fix it by editing the live object (`kubectl edit`, `patch`, `set`) or by fixing the file and re-applying, whichever you would do at work.
4. Run `./check.sh NN` for that drill. Stop the timer.
5. `kubectl delete -f drills/NN-*.yaml` and move on.

Target: every drill under 5 minutes, and you can explain the root cause in one sentence. Repeat the set a week later without looking at your notes.

Each drill deploys into namespace `drill`. Create it once: `kubectl create ns drill`.

## The drills

| # | File | Symptom you will see | Topic |
|---|---|---|---|
| 01 | `drills/01-image.yaml` | Pod never runs | Images and registries |
| 02 | `drills/02-crash.yaml` | Pod restarts forever | Container startup |
| 03 | `drills/03-pending.yaml` | Pod never scheduled | Scheduling and resources |
| 04 | `drills/04-selector.yaml` | Service answers nothing | Labels and endpoints |
| 05 | `drills/05-probe.yaml` | Pods Running but 0/1, rollout stuck | Probes |
| 06 | `drills/06-config.yaml` | Pod stuck before start | ConfigMaps and Secrets |
| 07 | `drills/07-dns.yaml` | App logs cannot resolve host | DNS and Service names |

Some drills have more than one bug. The check passes only when the workload actually works, not when one thing is fixed.

## The method, again

```
get pods            -> which STATUS
describe pod        -> Events, Last State, Conditions
logs [--previous]   -> what the app said
get endpointslices  -> does the Service see anyone
exec / run tmp      -> test from inside
```

If you are stuck for more than 10 minutes, open `REFERENCE.md`, "Debug flow". If still stuck, open the drill file, find the bug, then delete everything and redo the drill from scratch tomorrow.

## Quiz

Answer these from memory after finishing all seven.

1. `ErrImagePull` vs `ImagePullBackOff`. Same problem?
2. `CrashLoopBackOff` and `kubectl logs` shows nothing. Next command?
3. Pending, and `describe` says `0/1 nodes are available: 1 node(s) had untolerated taint`. What is a taint and what are your options?
4. Service has endpoints, pod is Ready, `curl` from another pod times out instead of refusing. What does the difference between timeout and refused tell you?
5. Rollout stuck, new pod `0/1`, `describe` shows `Readiness probe failed: HTTP probe failed with statuscode: 404`. Two possible root causes.
6. Interview: "A deploy went out 10 minutes ago and error rate is up. What do you do in the first two minutes?"

<details>
<summary>Answers</summary>

1. Same problem, different moment. `ErrImagePull` is the pull attempt failing right now, `ImagePullBackOff` is the kubelet waiting with exponential backoff before trying again. Both mean wrong image name or tag, private registry without `imagePullSecrets`, or the registry is down.
2. `kubectl logs POD --previous` for the last crashed container's output. If still empty, `describe` for the exit code: 1 is app error, 137 is OOMKilled or SIGKILL, 126/127 is command not found or not executable, and check `command`/`args` against the image's entrypoint.
3. A taint on a node repels pods unless they carry a matching toleration. Control-plane nodes and special hardware pools use them. Options: add a toleration to the pod, remove the taint from the node, or accept that the pod belongs elsewhere and add nodes to the untainted pool.
4. Refused means something answered and said no: nothing listening on that port, wrong `targetPort`. Timeout means packets are dropped: NetworkPolicy, a firewall, a wrong IP, or kube-proxy rules missing. Refused is an app or port problem, timeout is a network problem.
5. The probe path is wrong for this app version (the route moved or does not exist), or the app serves on a different port or path prefix than configured. Either way the probe config and the app disagree. Check `curl` from inside the pod against the same path.
6. `kubectl rollout undo` first if the timing matches, ask questions after. Then `kubectl get pods` for restarts and readiness, `rollout history` to confirm what changed, logs of a new pod, `get events`. Communicate in the incident channel what you rolled back and why. Root cause comes after the bleeding stops.
</details>

## Task

Write your own drill. A manifest with one or two bugs that produce a symptom not covered above, for example a wrong `serviceAccountName`, a `hostPort` conflict, a `securityContext` that stops the app from writing, a PVC with a non-existent StorageClass. Give it to a friend or to a future you. Add a check case for it in `check.sh`.
