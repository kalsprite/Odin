#!/usr/bin/env bash
# Sweep task-number references in checker comments. A `task #N` citation is true when written
# and can be silently falsified later by that task closing with a DIFFERENT conclusion --
# unlike a C++ line citation, which citefn.py can detect drifting. See LEDGER progress#267/268.
#
# This lists every reference with its file:line so they can be eyeballed against the task list.
# It cannot decide correctness automatically: the failure is semantic (comment claims X, task
# concluded not-X), not syntactic.
cd /home/kalsprite/dev/odin
grep -rnoE "(task|TASK|Task) #[0-9]+" core/odin/checker/*.odin core/odin/parser/*.odin 2>/dev/null |
  sed 's/:\(task\|TASK\|Task\) /  /' | sort -t'#' -k2 -n
echo "--- distinct: $(grep -rhoE '(task|TASK|Task) #[0-9]+' core/odin/checker/*.odin core/odin/parser/*.odin 2>/dev/null | grep -oE '[0-9]+' | sort -nu | tr '\n' ' ')"
