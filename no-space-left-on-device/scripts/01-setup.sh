#!/usr/bin/env bash
# Sets up a loop-mounted ext4 filesystem with deliberately few inodes,
# so both failure modes can be reproduced safely without touching real disk hardware.
set -euo pipefail

IMG=/tmp/lab.img
MNT=/mnt/lab

dd if=/dev/zero of="$IMG" bs=1M count=200
mkfs.ext4 -N 1024 -F "$IMG"   # only 1024 inodes on a 200MB image, on purpose

sudo mkdir -p "$MNT"
sudo mount -o loop "$IMG" "$MNT"

echo "--- mounted ---"
df -h "$MNT"
df -i "$MNT"
