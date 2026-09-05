# Support & Infrastructure Case Studies

Real troubleshooting incidents from my own labs and infrastructure work, written up as diagnosis narratives — what broke, how I isolated the root cause, and how I fixed it. Companion to my Linux / Cloud Support Engineer résumé.

Each case follows the same shape:

1. **Symptom** — what broke, what a check first showed
2. **Investigation** — the actual commands and reasoning, including misleading signals and dead ends
3. **Root Cause** — what was actually wrong
4. **Fix** — what changed, and why that specific change
5. **Skills Demonstrated** — the transferable diagnostic method, not just the one-line fix

## Cases

| Case | Stack | Summary |
|---|---|---|
| [`kubernetes-node-join-failure/`](kubernetes-node-join-failure/) | Kubernetes, kubeadm, Vagrant/VirtualBox, Calico | Worker nodes failed to join a kubeadm cluster; a misleading `ping` success masked a multi-homed node advertising the wrong API server address. Diagnosed with layered network tests (`ping` → `nc` → `ss`), then fixed with an explicit `--apiserver-advertise-address`. |
| [`no-space-left-on-device/`](no-space-left-on-device/) | Linux, ext4, `df`/`du`/`lsof` | Two "No space left on device" tickets, two different root causes: inode exhaustion (bytes free, no inode slots left) and a deleted log file still held open by a process (space not reclaimed until the descriptor closes). Diagnosed with `df -i` and `lsof +L1`. |

More cases will be added as they're written up.
