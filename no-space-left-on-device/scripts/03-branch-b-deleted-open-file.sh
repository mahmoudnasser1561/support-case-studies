#!/usr/bin/env bash
# Branch B: write a large file, hold it open (simulating a daemon with the
# file descriptor still live), then delete it. `df` still reports the space
# as used; `du` sees nothing; `lsof +L1` reveals who's actually holding it.
set -uo pipefail

MNT=/mnt/lab

sudo dd if=/dev/zero of="$MNT/big.log" bs=1M count=150

echo "--- df -h after writing big.log ---"
df -h "$MNT"

sudo bash -c "
  exec 3< $MNT/big.log
  rm $MNT/big.log
  sleep 60 &
  HOLDER_PID=\$!
  echo \"holder PID: \$HOLDER_PID\"
  sleep 1

  echo '--- df -h (still full - deleted file, space not reclaimed) ---'
  df -h $MNT

  echo '--- du -sh (nearly empty - the contradiction) ---'
  du -sh $MNT

  echo '--- lsof +L1 (deleted file, still held open, link count 0) ---'
  lsof +L1 $MNT 2>/dev/null | grep -E 'COMMAND|big.log'

  wait \$HOLDER_PID 2>/dev/null
"
