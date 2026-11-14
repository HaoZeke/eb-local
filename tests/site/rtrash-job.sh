#!/bin/bash
# Site acceptance: eb-local with the real rtrash, in an allocation.
#
#   sbatch --export=ALL,EB_LOCAL_TEST_ROOT=DIR,EB_LOCAL_BIN=/path/eb-local,RTRASH=/path/rtrash \
#       tests/site/rtrash-job.sh
#
# clean moves an old log to the trash and rtrash restore brings it back;
# uninstall moves a read-only installation and its module file to the trash,
# restore brings both back and the program runs again. The trash lives under
# DIR (XDG_DATA_HOME). DIR holds eb-local.conf; remove DIR afterwards (in a
# batch job on Snellius).
#SBATCH --job-name=eb-local-rtrash
#SBATCH --partition=rome
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --time=00:30:00
#SBATCH --constraint=scratch-node
# No -u: the Lmod init reads unset variables.
set -eo pipefail
module purge
# rtrash records the resolved path, so every path here is resolved too.
T=$(readlink -f "${EB_LOCAL_TEST_ROOT:?set EB_LOCAL_TEST_ROOT}")
EL=${EB_LOCAL_BIN:?set EB_LOCAL_BIN}
RT=${RTRASH:?set RTRASH to an rtrash binary}
RTDIR=$(dirname "$RT")
export XDG_DATA_HOME=$T/xdg PATH=$RTDIR:$PATH
export EB_LOCAL_CONFIG=$T/eb-local.conf EB_LOCAL_PREFIX=$T/eessi
"$EL" --version
rtrash --version
pass=0; fail=0
check() { if "$@"; then echo "PASS $*"; pass=$((pass+1)); else echo "FAIL $*"; fail=$((fail+1)); fi; }
cd "$T"

echo "== build pigz"
check "$EL" pigz-2.8-GCCcore-15.2.0.eb --robot
inst=$(ls -d "$T"/eessi/versions/2026.06/software/linux/*/*/*/software/pigz/2.8-GCCcore-15.2.0)
mod=$(ls "$T"/eessi/versions/2026.06/software/linux/*/*/*/modules/all/pigz/2.8-GCCcore-15.2.0.lua)
check test ! -w "$inst"

echo "== clean of an old log goes to the trash"
log=$EB_LOCAL_PREFIX/.eb-local/logs/probe/old.log
mkdir -p "$(dirname "$log")"; echo old > "$log"; touch -d '40 days ago' "$log"
check "$EL" clean
check test ! -e "$log"
check grep -qF "$log" <(rtrash list)
check rtrash restore "$log"
check test -e "$log"

echo "== uninstall goes to the trash, restore brings it back"
check "$EL" uninstall pigz/2.8-GCCcore-15.2.0
check test ! -e "$inst"
check test ! -e "$mod"
check rtrash restore "$inst"
check rtrash restore "$mod"
check env -i PATH=/usr/bin:/bin "$inst/bin/pigz" --version
rc=0; ( eval "$("$EL" env)"; module load pigz/2.8-GCCcore-15.2.0; [ "$(command -v pigz)" = "$inst/bin/pigz" ] ) || rc=$?
check test "$rc" -eq 0

echo "== the trash empties"
check rtrash empty
check test -z "$(rtrash list 2>/dev/null)"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
