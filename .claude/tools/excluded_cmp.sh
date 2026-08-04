#!/usr/bin/env bash
# Direct oracle-vs-port error-count comparison for packages the sweep EXCLUDES
# (capped or crashed). swdiff drops these before comparing, so they are unmeasured.
cd /home/kalsprite/dev/odin
PORT="$1"; LIST="$2"
while read -r p; do
  [ -z "$p" ] && continue
  o=$(timeout 180 ./odin check "$p" -no-entry-point 2>&1 | grep -c "Error:")
  orc=$?
  pt=$(timeout 180 "$PORT" "$p" 2>&1 | grep -c "Error:")
  printf "%-50s oracle=%-6s port=%s\n" "$p" "$o" "$pt"
done < "$LIST"
echo "EXCLUDED-CMP-DONE"
