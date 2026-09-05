# Filesystem Full but Empty: Diagnosing Inode Exhaustion and Deleted-Open Files

**TL;DR:** Two "No space left on device" tickets landed back to back while I was provisioning storage for a logging volume, and neither was a normal full disk. The first: `df -h` showed the volume was nearly empty, yet every new file write failed instantly. The second: `df -h` showed the volume genuinely full, but `du -sh` showed almost nothing on it. Same error message, two completely different root causes — one was inode exhaustion (the filesystem ran out of "slots" to register new files, not out of bytes), the other was a large log file deleted while a process still held it open (the space isn't reclaimed until the file descriptor closes). I isolated each with a different decisive test and fixed both.

---

## Environment

Reproduced on a loop-mounted ext4 filesystem, deliberately built with very few inodes, to isolate each failure mode safely without touching real disk hardware or a production volume.

| Component | Detail |
|---|---|
| Filesystem | ext4, loop-mounted, 200MB image, 1,024 inodes (deliberately constrained) |
| Tools used | `df`, `du`, `lsof`, `dd`, `mkfs.ext4` |
| Host | Ubuntu (WSL/Linux) |

```bash
dd if=/dev/zero of=/tmp/lab.img bs=1M count=200
mkfs.ext4 -N 1024 /tmp/lab.img        # only 1024 inodes, on purpose
sudo mount -o loop /tmp/lab.img /mnt/lab
```

---

## Symptom

**Ticket 1:** An application couldn't write a new file — `No space left on device` — even though the volume had just been checked and looked nearly empty.

**Ticket 2:** A separate volume, already known to be near capacity, kept refusing writes even after a large log file had supposedly been deleted specifically to free up space. The deletion appeared to succeed, but the error didn't go away.

Both produce the identical error string. Both look, at first glance, like "the disk is full, add more space." Neither actually was.

## First (Misleading) Signal

The instinctive first check for "no space left" is `df -h` — and it gave the wrong answer in both directions.

**Ticket 1**, after filling the filesystem with 2,000 small files:

```
$ df -h /mnt/lab
Filesystem      Size  Used Avail Use% Mounted on
/dev/loop16     184M   44K  170M   1%  /mnt/lab

$ touch /mnt/lab/x
touch: cannot touch '/mnt/lab/x': No space left on device
```

1% used, 170M free — and the write still fails. If you stop at `df -h`, this looks like a filesystem bug or a permissions problem. It's neither.

**Ticket 2**, after writing a 150MB log file and then deleting it while a process still held it open:

```
$ df -h /mnt/lab
Filesystem      Size  Used Avail Use% Mounted on
/dev/loop16     184M  151M   20M  89%  /mnt/lab

$ du -sh /mnt/lab
40K     /mnt/lab
```

`df` says 89% full. `du` — which walks the actual directory tree — says 40K. Two standard, trusted tools disagreeing about the same filesystem. That contradiction is the tell.

## The Decisive Test

Each branch needed a different follow-up, because each branch was hiding a different resource.

**Ticket 1 — check inodes, not bytes:**

```
$ df -i /mnt/lab
Filesystem     Inodes IUsed IFree IUse% Mounted on
/dev/loop16      1024  1024     0  100%  /mnt/lab
```

100% inode usage, 0 free — with the filesystem barely using any actual space. `df -h` measures capacity in bytes; it has nothing to say about how many files a filesystem can still register. Those are two separate limits, and only one of them was exhausted.

**Ticket 2 — find who's still holding the deleted file open:**

```
$ lsof +L1 /mnt/lab
COMMAND    PID  USER  FD  TYPE DEVICE       SIZE/OFF NLINK  NODE NAME
bash     69700  root   3r  REG   7,16      157286400     0    12 /mnt/lab/big.log (deleted)
sleep    69702  root   3r  REG   7,16      157286400     0    12 /mnt/lab/big.log (deleted)
```

`lsof +L1` lists open files with a link count of zero — exactly the signature of "deleted but still referenced." The file is gone from the directory tree (which is why `rm` "succeeded" and `du` sees nothing), but the 150MB it occupied is still allocated on disk because a process (PID 69700, and a child at 69702) still has an open file descriptor pointing at it.

## Root Cause

**Ticket 1 — Inode exhaustion.** A filesystem has two independent capacity limits: space (bytes) and inodes (the metadata slots needed to track a file's existence). This filesystem was deliberately small on inodes (1,024) relative to its size, and a process had created thousands of tiny files, consuming every inode long before the byte capacity was threatened. `df -h` only reports the byte limit, so it looked completely healthy while the real limit — the one that was actually blocking writes — was invisible to it.

**Ticket 2 — Deleted file, held open.** On Linux, `rm` unlinks a filename from the directory tree; it does **not** free the underlying disk blocks if a process still has that file open. The kernel only reclaims the space when every process holding a file descriptor to it closes that descriptor. `rm` had genuinely run and succeeded — the file was gone from every directory listing — but the daemon that had it open (simulated here by a backgrounded `bash`/`sleep` holding fd 3) kept the blocks allocated.

## The Fix

**Ticket 1:** Freed inodes by removing the excess small files (in production, this is where you'd batch-delete or archive whatever process is inode-bombing the filesystem — a log rotation gone wrong, a cache never cleaning up, a queue directory with one file per message):

```bash
sudo rm -f /mnt/lab/f_*
```

Longer-term, an inode-starved filesystem this size should be rebuilt with more inodes (`mkfs.ext4` without an artificially low `-N`), since the ratio — not just the total size — was the actual constraint.

**Ticket 2:** Space isn't reclaimed by re-running `rm` (there's nothing left to remove) — it's reclaimed by making the holding process release the descriptor:

```bash
# Preferred: restart/reload the service that's still holding the file
sudo systemctl restart <the-service>

# If a restart isn't acceptable right now: truncate the open descriptor directly
sudo bash -c '> /proc/69700/fd/3'
```

Truncating via `/proc/<pid>/fd/<fd>` reclaims the space immediately without killing the process — useful for a service you can't safely restart mid-shift — but a full restart is the cleaner fix since it also closes and reopens any downstream log handlers cleanly.

---

## Troubleshooting Methodology

The same error string, two causes, one decision tree:

```
Write fails: "No space left on device"
        │
        ▼
   df -h  →  is the filesystem actually full (by bytes)?
        │
   ┌────┴─────┐
   │          │
 ~100%      not full
   │          │
   ▼          ▼
 du -sh     df -i  →  inodes exhausted?
   │              (many tiny files; space free,
┌──┴──┐            but no room left to *register*
│     │            a new file)
matches  du ≪ df
│        │
genuine  deleted-but-open file
data     (space not reclaimed until the
full     holding process closes the fd)
         → lsof +L1 to find the PID
```

The discipline this enforces: `df -h` answers exactly one question — "how many bytes are used?" — and nothing else. Treating a "no space left" error as automatically a bytes problem skips two other, equally common causes that need entirely different fixes.

## Prevention

- **Monitor `df -i` alongside `df -h`, not instead of it.** Most default Prometheus node-exporter / Grafana dashboards graph filesystem usage in bytes and silently omit inode usage entirely. A filesystem can be one file away from inode exhaustion while every byte-based dashboard panel shows green. Add an explicit inode-usage panel and alert threshold — this failure mode is invisible without one.
- **Configure `logrotate` with `copytruncate` for daemons that hold their log file open for the process lifetime.** Standard `logrotate` renames the old log and signals the daemon to reopen a new file descriptor — if the daemon doesn't support that signal (or the rotation config is wrong), you get exactly Ticket 2: a "deleted" log still consuming its full size because the original descriptor is still live. `copytruncate` avoids this by copying the log contents out and truncating the original file in place, so the daemon's existing file descriptor stays valid and the disk space is reclaimed immediately.

## Skills Demonstrated

- **Distinguishing filesystem resource types** — bytes vs. inodes vs. open-file-descriptor accounting — and knowing which command answers which question (`df -h`, `df -i`, `du -sh`, `lsof +L1`)
- **Linux filesystem/VFS internals** — why `rm` doesn't always free space, the unlink-vs-close distinction, and how to reclaim space from a live process without a service restart when one isn't acceptable
- **Not trusting the first tool's answer** — the same discipline as the Kubernetes case: a green or plausible-looking result from one tool doesn't rule out the actual failure mode until it's been checked against the specific resource that's exhausted
- **Operational prevention, not just firefighting** — identifying a real monitoring blind spot (inode metrics missing from typical dashboards) and a concrete logging configuration fix (`copytruncate`), not just resolving the immediate incident

## Reference

Reproduction scripts: [`scripts/`](scripts/)
