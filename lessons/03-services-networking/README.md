# 03. Services and networking

Goal: expose pods to each other and to the outside. ClusterIP, NodePort, LoadBalancer, DNS, Ingress. Know exactly how a request finds a pod.

## Concept

Pods get an IP each, from `10.42.0.0/16` here. Pod IPs change every time a pod is replaced, so nothing should talk to a pod IP. A **Service** is a stable virtual IP (from `10.43.0.0/16`) plus a DNS name that load balances across pods selected by label.

```
client --> Service ClusterIP 10.43.x.x:80 --> (kube-proxy iptables DNAT) --> pod 10.42.0.7:8080
                                                                          --> pod 10.42.0.9:8080
```

The Service does not proxy anything. kube-proxy watches Services and EndpointSlices and writes iptables rules on every node. A packet to the ClusterIP is rewritten in the kernel to a pod IP. That is why the ClusterIP never shows up in `ss -ltn` on the node, and why a broken kube-proxy means Services silently black-hole.

Four ways to be reached:

| Type | Reachable from | ECS analogy |
|---|---|---|
| `ClusterIP` (default) | Inside the cluster only | Cloud Map service discovery |
| `NodePort` | `<any node IP>:30000-32767` | Host port mapping |
| `LoadBalancer` | External IP from a provider | NLB. Here KubeSolo assigns the node IP |
| `Ingress` | HTTP(S) router in front of Services | ALB with host and path rules. Needs a controller |

DNS: every Service gets `name.namespace.svc.cluster.local`. Pods in the same namespace can use just `name`. The `search` list in `/etc/resolv.conf` does that expansion.

## Walkthrough

### ClusterIP and endpoints

```sh
kubectl apply -f app.yaml           # two deployments: frontend and backend, one Service each
kubectl get svc,endpointslices
kubectl get pods -o wide
```

Compare the endpoint IPs with the pod IPs. Same numbers. Now the interesting part:

PREDICT: you scale backend to 0. What happens to the `backend` EndpointSlice? To the Service IP?

```sh
kubectl scale deploy backend --replicas=0
kubectl get endpointslices -l kubernetes.io/service-name=backend
kubectl scale deploy backend --replicas=2
```

Service stays, endpoints empty. That is what "connection refused" from a Service usually means: no ready pods behind it.

### Call it by name

```sh
kubectl exec deploy/frontend -- wget -qO- http://backend:8080
kubectl exec deploy/frontend -- wget -qO- http://backend.default.svc.cluster.local:8080
kubectl exec deploy/frontend -- cat /etc/resolv.conf
```

PREDICT: does `wget http://backend` work from a pod in a different namespace?

```sh
kubectl create ns other
kubectl -n other run tmp --image=busybox:1.36 --restart=Never --rm -it -- wget -qO- --timeout=3 http://backend:8080
kubectl -n other run tmp --image=busybox:1.36 --restart=Never --rm -it -- wget -qO- --timeout=3 http://backend.default:8080
```

### Selector mismatch, the classic bug

Edit `app.yaml`, change the backend Service selector to `app: backnd` (typo). Apply.

```sh
kubectl get endpointslices -l kubernetes.io/service-name=backend    # no endpoints
kubectl exec deploy/frontend -- wget -qO- --timeout=3 http://backend:8080   # fails
```

Fix the typo, apply. This is the first thing to check whenever a Service does not answer.

### NodePort

```sh
kubectl patch svc frontend -p '{"spec":{"type":"NodePort"}}'
kubectl get svc frontend            # PORT(S) 80:3XXXX/TCP
NODE_IP=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl http://$NODE_IP:$(kubectl get svc frontend -o jsonpath='{.spec.ports[0].nodePort}')
```

That curl runs on your mac and reaches a pod. Works on every node of a real cluster, on the same port.

### LoadBalancer

```sh
kubectl patch svc frontend -p '{"spec":{"type":"LoadBalancer"}}'
kubectl get svc frontend -w         # EXTERNAL-IP appears
curl http://$NODE_IP/
```

On EKS this would create an NLB and take two minutes. KubeSolo just uses the node IP. One LoadBalancer per port here, a second Service on port 80 will stay `<pending>`.

Set it back: `kubectl patch svc frontend -p '{"spec":{"type":"ClusterIP"}}'`.

### Ingress

Ingress objects do nothing until a controller exists. Install ingress-nginx with Helm (lesson 07 explains Helm, for now just run it):

```sh
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace
kubectl -n ingress-nginx get svc      # LoadBalancer with the node IP on 80 and 443
kubectl get ingressclass              # nginx
```

Now apply `ingress.yaml` and route by host:

```sh
kubectl apply -f ingress.yaml
kubectl get ingress
curl -H "Host: front.local" http://$NODE_IP/
curl -H "Host: back.local"  http://$NODE_IP/
curl http://$NODE_IP/                 # 404 from nginx, no rule matched
```

Add `front.local` and `back.local` to `/etc/hosts` pointing at the node IP if you want it in a browser.

Watch the controller pick up your rules:

```sh
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=20
```

### NetworkPolicy

Default is every pod can talk to every pod, across namespaces. NetworkPolicy restricts that, but only if the CNI enforces it. KubeSolo's bridge CNI does not. Read the skeleton in `REFERENCE.md`, know that it exists, practice it on kind with Calico later.

## Checkpoint

```sh
kubectl exec deploy/frontend -- wget -qO- http://backend:8080   # JSON from the backend
curl -s -H "Host: front.local" http://$NODE_IP/ | head -3
```

## Quiz

1. A Service has a ClusterIP but `curl` from a pod gives "connection refused". List three causes in the order you would check them.
2. `port`, `targetPort`, `nodePort`. Which one does the client use, which one does the pod listen on?
3. Can a Service select pods from two different Deployments? Why would you?
4. What does `ndots:5` in resolv.conf cause when a pod resolves `api.example.com`?
5. Why does an Ingress need a controller, while a Service does not?
6. Headless Service (`clusterIP: None`): what does DNS return and when do you want that?
7. Interview: "Request enters from the internet, hits a pod. Every hop."

<details>
<summary>Answers</summary>

1. No endpoints: selector does not match pod labels, or pods are not Ready (readiness probe). Wrong `targetPort`: pod listens on 8080 but Service targets 80. kube-proxy down or NetworkPolicy blocking. Check with `kubectl get endpointslices`, then `describe svc`, then `describe pod`.
2. Client uses `port` on the ClusterIP (or `nodePort` on a node IP). Pod listens on `targetPort`. `targetPort` defaults to `port`.
3. Yes, selectors are just labels. Blue/green: both versions carry `app: web`, Service sends to both, then you remove the label from the old one. Or a canary Deployment with fewer replicas.
4. Any name with fewer than 5 dots is tried with each search suffix first: `api.example.com.default.svc.cluster.local`, `api.example.com.svc.cluster.local`, `api.example.com.cluster.local`, then finally `api.example.com`. Four lookups before the right one. Fix with a trailing dot `api.example.com.` or lower ndots in `dnsConfig`.
5. Service is implemented by kube-proxy which every cluster has. Ingress is just data, an HTTP routing table. Something must read it and run a reverse proxy: ingress-nginx, Traefik, AWS Load Balancer Controller. Gateway API is the newer replacement with the same split.
6. DNS returns the pod IPs directly, one A record per pod, no virtual IP. StatefulSets use it so `db-0.db` addresses a specific pod. Also for client-side load balancing like gRPC.
7. DNS resolves to the LoadBalancer IP. LB forwards to a NodePort on some node. kube-proxy iptables on that node DNATs to the ingress controller pod, possibly on another node. Ingress controller matches host and path, proxies to the backend Service ClusterIP. kube-proxy DNATs again to an application pod IP. CNI routes to the pod's network namespace. Reply follows the conntrack entries back.
</details>

## Task

Deploy `httpbin` and expose it three ways. From scratch:

- Deployment `httpbin`, 2 replicas, image `mccutchen/go-httpbin`, container port 8080, labels `app: httpbin`
- Service `httpbin` type ClusterIP on port 8080 targeting container port 8080
- Ingress `httpbin` with host `httpbin.local`, path `/`, class `nginx`, pointing at the Service

Verify:

```sh
kubectl run tmp --image=busybox:1.36 --restart=Never --rm -it -- wget -qO- http://httpbin:8080/get
curl -s -H "Host: httpbin.local" http://$NODE_IP/get
./check.sh
```

Clean up: `kubectl delete -f app.yaml -f ingress.yaml; kubectl delete deploy,svc,ingress httpbin; kubectl delete ns other`. Keep ingress-nginx installed, later lessons use it.
