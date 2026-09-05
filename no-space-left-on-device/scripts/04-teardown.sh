#!/usr/bin/env bash
# Tears down the lab filesystem completely.
set -uo pipefail

MNT=/mnt/lab
IMG=/tmp/lab.img

sudo umount "$MNT" 2>/dev/null
sudo rmdir "$MNT" 2>/dev/null
rm -f "$IMG"

echo "cleanup done"
