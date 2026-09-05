#!/usr/bin/env bash
# Branch A: exhaust inodes with many tiny files. Space stays nearly empty
# (the misleading `df -h` signal) while writes fail because there is no
# inode slot left to register a new file.
set -uo pipefail

MNT=/mnt/lab

sudo bash -c "for i in \$(seq 1 2000); do touch $MNT/f_\$i 2>/dev/null; done"

echo "--- df -h (looks nearly empty) ---"
df -h "$MNT"

echo "--- attempting a new write ---"
sudo touch "$MNT/x" || true

echo "--- df -i (the real answer: 100% inode usage) ---"
df -i "$MNT"

echo "--- cleanup: freeing inodes ---"
sudo rm -f "$MNT"/f_*
