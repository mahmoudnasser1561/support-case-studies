# Kubernetes Join Failure: Diagnosing a Multi-Homed Node Misconfiguration

**TL;DR:** A 3-node on-prem Kubernetes cluster (Vagrant/VirtualBox) failed to join its workers to the control plane. `ping` to the control plane succeeded, which was misleading — the real fault was that `kubeadm init` had auto-selected the wrong network interface to advertise the API server on. I isolated this with a layered network test (`ping` → `nc` → `ss`), distinguishing "host reachable" from "port reachable" from "service correctly advertised," then fixed it with an explicit `--apiserver-advertise-address` flag. Two downstream failures (a stale TLS kubeconfig, and nodes stuck `NotReady`) followed the same fix-and-verify pattern.

---

## Environment

| Component | Detail |
|---|---|
| Virtualization | Vagrant + VirtualBox |
| OS | Ubuntu 24.04 LTS |
| Kubernetes | v1.35.7 (kubeadm) |
| CNI | Calico v3.28.0 |
| Topology | 1 control-plane node + 2 worker nodes |
| Intended cluster network | `192.168.56.0/24` (VirtualBox host-only/private network) |

```
                 Host-only network (192.168.56.0/24)
                       │
        ┌──────────────┼──────────────┐
        │              │              │
        ▼              ▼              ▼
   k8s-control     k8s-worker-1   k8s-worker-2
   .10                .11            .12
```

Each VM also carries a second, VirtualBox-managed NAT interface (used for internet access / package downloads) at `10.0.2.15`. That second interface is the entire story below.

---

## Symptom

`kubeadm init` on the control plane completed successfully and printed a join command:

```bash
kubeadm join 10.0.2.15:6443 \
  --token ... \
  --discovery-token-ca-cert-hash sha256:...
```

Running that exact command on `k8s-worker-1` hung indefinitely at:

```
[preflight] Running pre-flight checks
```

## First (Misleading) Signal

The obvious first check — can the worker even see the control plane? — came back clean:

```bash
$ ping 10.0.2.15
64 bytes from 10.0.2.15: icmp_seq=1 ttl=64 time=0.3ms
```

This looked like proof of connectivity. It wasn't. Every VM in a Vagrant/VirtualBox NAT setup gets its **own isolated** NAT interface at the same default address (`10.0.2.15`) — it's not a shared LAN segment. So `ping 10.0.2.15` from Worker 1 was really just pinging *itself*, not the control plane:

```
Worker 1  ──ping 10.0.2.15──▶  Worker 1's own NAT interface   ❌ not the control plane
```

This is the trap: a green ICMP result gave false confidence and would have sent a less careful diagnosis down the wrong path (blaming firewalls, tokens, or Calico) rather than the network layer.

## The Decisive Test

Since ICMP couldn't be trusted, I moved one layer up the stack and tested the actual port `kubeadm` needed — TCP 6443 — against both candidate addresses:

```bash
$ nc -vz 10.0.2.15 6443
nc: connect to 10.0.2.15 port 6443 (tcp) failed: Connection refused

$ nc -vz 192.168.56.10 6443
Connection to 192.168.56.10 6443 port [tcp/*] succeeded!
```

That was conclusive. "Connection refused" (not "timed out") meant the host itself was reachable but nothing was listening there for this worker — while the cluster network address worked immediately.

```
Worker 1
   ├── 10.0.2.15:6443       ❌ Connection refused
   └── 192.168.56.10:6443   ✅ Succeeded
```

## Confirming Root Cause on the Control Plane

Checking the API server's listener showed it was actually bound to *all* interfaces, ruling out a simple bind misconfiguration:

```bash
$ sudo ss -lntp | grep 6443
LISTEN 0 4096 *:6443 *:* users:(("kube-apiserver",pid=3295,fd=4))
```

The real problem was one level higher — not *what* the API server was listening on, but *what address kubeadm had told the rest of the cluster to use*:

```bash
$ sudo grep advertise /etc/kubernetes/manifests/kube-apiserver.yaml
kubeadm.kubernetes.io/kube-apiserver.advertise-address.endpoint: 10.0.2.15:6443
--advertise-address=10.0.2.15
```

**Root cause:** the control-plane node is multi-homed (a NAT interface *and* a private cluster interface). Run without an explicit hint, `kubeadm init` auto-selected the NAT interface (`10.0.2.15`) as the API server's advertised address — an address that is not unique or reachable across VMs — instead of the intended cluster network address (`192.168.56.10`). Every worker was then handed a join command pointing at an endpoint that, from its own perspective, resolved to itself.

## The Fix

Reset the cluster and re-initialized with the advertise address made explicit:

```bash
sudo kubeadm reset
sudo kubeadm init \
  --apiserver-advertise-address=192.168.56.10 \
  --pod-network-cidr=192.168.0.0/16
```

Verified in the output before even attempting a join:

```
apiserver serving cert is signed for DNS names [...] and IPs [10.96.0.1 192.168.56.10]
[control-plane-check] Checking kube-apiserver at https://192.168.56.10:6443/livez
```

The generated join command now correctly read `192.168.56.10:6443`, and both workers joined cleanly:

```
[kubelet-start] Waiting for the kubelet to perform the TLS Bootstrap
This node has joined the cluster:
* Certificate signing request was sent to apiserver and a response was received.
* The Kubelet was informed of the new secure connection details.
```

## Downstream Issue #1: Stale Kubeconfig (TLS Mismatch)

After the fix, `kubectl get nodes` immediately surfaced a second, unrelated-looking failure:

```
Unable to connect to the server: tls: failed to verify certificate:
x509: certificate is valid for 10.96.0.1, 192.168.56.10, not 10.0.2.15
```

`grep server ~/.kube/config` confirmed the leftover kubeconfig from the *first* (broken) `kubeadm init` still pointed at `10.0.2.15` — while the new API server's certificate was only valid for `192.168.56.10`. Resolved by re-pulling the current cluster's admin config rather than reusing the stale one:

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
```

**Takeaway:** `/etc/kubernetes/admin.conf` is scoped to the cluster instance created by a specific `kubeadm init`. Resetting and recreating a cluster invalidates any previously saved `~/.kube/config`.

## Downstream Issue #2: Nodes Stuck `NotReady`

With networking and auth resolved, all three nodes registered but sat in `NotReady` — expected, since joining a cluster and having pod networking are two separate concerns. Installed Calico to close the gap:

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

```
NAME           STATUS   ROLES           INTERNAL-IP
k8s-control    Ready    control-plane   192.168.56.10
k8s-worker-1   Ready    <none>          192.168.56.11
k8s-worker-2   Ready    <none>          192.168.56.12
```

---

## Troubleshooting Methodology (Reusable)

The specific fix here is one line. The reason it's worth documenting is the layered diagnostic method that got there — the same approach applies to any "node A can't reach service B" problem, on-prem or cloud:

```
kubeadm join hangs
        │
        ▼
Layer 1 — ICMP reachable?          ping <ip>                (proves network path only, NOT service reachability)
        │
        ▼
Layer 2 — Port reachable?          nc -vz <ip> 6443
        │
   ┌────┴────┐
   │         │
"refused"  "timed out"          "succeeded"
   │         │                       │
host up,   routing/firewall/     move to Layer 3
nothing    wrong IP entirely
listening
there
        │
        ▼
Layer 3 — Is the service listening where expected?   ss -lntp | grep <port>
        │
        ▼
Layer 4 — What address is the service *advertising* to clients?
          (the actual root cause layer in this case — a correctly
           running service can still hand out the wrong endpoint)
```

The key discipline demonstrated: **don't trust the first green signal.** `ping` succeeding felt like progress but was measuring the wrong thing entirely; the investigation only converged once the test matched the actual failure mode (a specific TCP port, to a specific advertised address).

## Skills Demonstrated

- **Layered network diagnosis** — ICMP vs. TCP vs. application-layer reachability, and knowing which tool answers which question (`ping`, `nc`, `ss`, `curl`)
- **Multi-homed host networking** — reasoning about NAT vs. private/host-only interfaces in a virtualized lab, a pattern that generalizes directly to multi-NIC cloud instances and bastion/VPC setups
- **Kubernetes cluster bootstrap internals** — `kubeadm init`/`join`, `--apiserver-advertise-address`, TLS certificate SANs, kubeconfig scoping, and the join-vs-ready distinction (CNI dependency)
- **Root-cause discipline** — distinguishing "the service is misconfigured" from "the service is fine but everyone was told the wrong address," which changed where the fix actually needed to go
- **Clear incident documentation** — the kind of writeup a teammate or the next on-call engineer could follow without re-deriving the diagnosis

## Reference
Cluster provisioning source: [`Vagrantfile`](Vagrantfile)
