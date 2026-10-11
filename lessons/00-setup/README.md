# 00. Setup and cluster anatomy

Goal: reach the cluster from your mac with all tools, and know what is running where so you can fix it when it breaks.

## How this cluster is built

```
macOS (arm64)
└── OrbStack machine "kubesolo" (Ubuntu, shares the mac kernel)
    └── systemd service "kubesolo"  = one process that embeds:
        kube-apiserver, controller-manager, scheduler, kubelet,
        kube-proxy, CoreDNS, containerd, kine (SQLite behind an etcd API),
        local-path storage provisioner, service load balancer
    └── add-ons installed as normal pods: metrics-server (kube-system)
```

A normal cluster runs each of those as a separate process or pod, usually across many machines. KubeSolo squashes them into one binary for edge devices. The API you talk to is identical, which is all that matters for learning.

Three things about this environment are non-standard. Remember them when something looks odd:

1. **Almost no system pods.** `kubectl get pods -n kube-system` shows only `metrics-server`, because CoreDNS and friends run inside the kubesolo process. Real clusters show them all as pods.
2. **One node.** Anything about scheduling across nodes, draining, taints, or node failure cannot be practiced here.
3. **OrbStack cannot write host kernel sysctls.** kube-proxy needs to, so a shim bind-mounts writable copies. See "Repairs" below.

## Tools on the mac

```sh
brew install helm k9s kubectx
kubectl version --client
```

- `helm` for lesson 07.
- `k9s` terminal UI. Run it, press `:pods`, `:deploy`, `:svc`, `l` for logs, `d` describe, `s` shell, `ctrl-d` delete. Use it constantly.
- `kubectx` / `kubens` switch cluster and namespace.

Put the kubeconfig in your shell profile so every terminal sees the cluster:

```sh
echo 'export KUBECONFIG=$HOME/.kube/kubesolo.yaml' >> ~/.zshrc
```

Where it came from:

```sh
orb -m kubesolo sudo cat /var/lib/kubesolo/pki/admin/admin.kubeconfig > ~/.kube/kubesolo.yaml
```

## Checkpoint

```sh
kubectl get nodes -o wide          # STATUS Ready, note the INTERNAL-IP
kubectl get storageclass           # local-path (default)
kubectl top node                   # CPU and memory of the node
kubectl cluster-info
```

The node INTERNAL-IP (`192.168.139.18` at time of writing) is also the IP that `LoadBalancer` services get. If the VM is recreated it may change. Always read it from `kubectl get nodes -o wide`, never hardcode.

## Poke the control plane

Everything in Kubernetes is an HTTP resource. Prove it:

```sh
kubectl get --raw /api/v1/namespaces/default/pods | head -c 400
kubectl api-resources | head -30
kubectl explain pod.spec.containers.livenessProbe
```

PREDICT: `kubectl get --raw /healthz` returns what?

## Repairs

Inside the VM (`orb -m kubesolo sudo sh`):

| Symptom | Cause | Fix |
|---|---|---|
| `kubectl` hangs or connection refused | kubesolo service down | `systemctl restart kubesolo`, then `journalctl -u kubesolo -n 100` |
| Pods run but DNS or Services fail | kube-proxy died on sysctl write | check `systemctl cat kubesolo` shows the `ExecStartPre` shim, then restart |
| No storage class | feature env missing | `/etc/systemd/system/kubesolo.service.d/features.conf` needs `KUBESOLO_LOCAL_STORAGE=true` |
| VM deleted | | `orb create ubuntu kubesolo`, install iptables, rerun installer, reapply the two drop-ins below |

Drop-ins that must exist in `/etc/systemd/system/kubesolo.service.d/`:

```ini
# orbstack-sysctl-shim.conf
[Service]
ExecStartPre=/usr/local/sbin/kubesolo-sysctl-shim.sh
```

```ini
# features.conf
[Service]
Environment=KUBESOLO_LOCAL_STORAGE=true
Environment=KUBESOLO_LOAD_BALANCER=true
```

metrics-server is a plain add-on, reinstall with:

```sh
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

The patch is needed because the kubelet serves a self-signed certificate here. Same trick on kind, minikube and k3s. Never do it in production, fix the kubelet certificate instead.

The shim script:

```sh
#!/bin/sh
# OrbStack machines share the host kernel and cannot write host-global
# netfilter sysctls. kube-proxy exits when that write fails, so bind a
# writable copy over each entry it touches.
set -e
d=/var/lib/kubesolo-sysctl-shim
mkdir -p "$d"
for k in nf_conntrack_max nf_conntrack_tcp_timeout_established nf_conntrack_tcp_timeout_close_wait nf_conntrack_tcp_be_liberal nf_conntrack_udp_timeout nf_conntrack_udp_timeout_stream; do
  p=/proc/sys/net/netfilter/$k
  [ -e "$p" ] || continue
  mountpoint -q "$p" && continue
  cat "$p" > "$d/$k"
  mount --bind "$d/$k" "$p"
done
```

## Quiz

1. Which component stores all cluster state, and what does KubeSolo use instead of it?
2. You run `kubectl apply`. Which component receives the request, which one decides the node, and which one starts the container?
3. Why is `kubectl get pods -n kube-system` empty here, and what would you expect on EKS?
4. What does kube-proxy do, and what stops working when it is down?

<details>
<summary>Answers</summary>

1. etcd. KubeSolo uses kine, which exposes the etcd API on top of SQLite.
2. kube-apiserver validates and stores the object. The scheduler watches for pods with no node and assigns one. The kubelet on that node sees the assignment and asks containerd to run the containers. The controller-manager is what turned your Deployment into a ReplicaSet into Pods in the first place.
3. Components are embedded in one process. On EKS you would see `coredns`, `kube-proxy`, `aws-node` (the CNI) as pods, and the control plane is hidden because AWS runs it.
4. It programs iptables (or nftables or IPVS) rules so that a Service ClusterIP gets DNAT'd to a pod IP. Without it, Service IPs including DNS at `10.43.0.10` are black holes. Pod-to-pod IP traffic still works.
</details>

## Task

Run `./check.sh`. It verifies tools, kubeconfig, node, storage class and DNS. Fix anything that fails using the repairs table.
