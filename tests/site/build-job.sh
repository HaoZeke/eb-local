#!/bin/bash
# Site acceptance in an allocation (Snellius values; adapt the #SBATCH lines):
#
#   EB_LOCAL_TEST_ROOT=DIR sbatch --output=DIR/job-%j.out --export=ALL tests/site/build-job.sh
#
# A build that leaves no workspace, its result used through env and with no
# modules at all, a failed build that keeps its workspace until clean removes
# it, clean of old logs without rtrash, and dev-tasks.sh on a compute node.
# DIR holds eb-local.conf; remove DIR afterwards (in a batch job on Snellius).
#SBATCH --job-name=eb-local-test
#SBATCH --partition=rome
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=8
#SBATCH --time=00:30:00
#SBATCH --constraint=scratch-node
# No -u: the Lmod init reads unset variables.
set -eo pipefail
module purge
T=${EB_LOCAL_TEST_ROOT:?set EB_LOCAL_TEST_ROOT}
HERE=$(dirname "$(readlink -f "${SLURM_SUBMIT_DIR:-.}/tests/site/build-job.sh" 2>/dev/null || readlink -f "$0")")
EL=${EB_LOCAL_BIN:-$HERE/../../eb-local}
export EB_LOCAL_CONFIG=$T/eb-local.conf EB_LOCAL_PREFIX=$T/eessi
JOB=/scratch-node/$USER.$SLURM_JOB_ID
pass=0; fail=0
check() { if "$@"; then echo "PASS $*"; pass=$((pass+1)); else echo "FAIL $*"; fail=$((fail+1)); fi; }
workspaces() { ls -d "$JOB"/eb-local.* 2>/dev/null | wc -l; }

echo "== build pigz"
rc=0; "$EL" pigz-2.8-GCCcore-15.2.0.eb --robot || rc=$?
check test "$rc" -eq 0
check test "$(workspaces)" -eq 0

echo "== use it through env, and with no modules"
rc=0
( eval "$("$EL" env)"; module load pigz/2.8-GCCcore-15.2.0; pigz --version; command -v pigz > "$T/pigz-path" ) || rc=$?
check test "$rc" -eq 0
check env -i PATH=/usr/bin:/bin "$(cat "$T/pigz-path")" --version

echo "== a failed build keeps its workspace; clean removes it"
rc=0; "$EL" no-such-easyconfig-1.0.eb || rc=$?
check test "$rc" -ne 0
check test "$(workspaces)" -eq 1
check "$EL" clean --workspaces --no-logs
check test "$(workspaces)" -eq 0

echo "== clean of old logs without rtrash"
mkdir -p "$EB_LOCAL_PREFIX/.eb-local/logs/probe"
log=$EB_LOCAL_PREFIX/.eb-local/logs/probe/old.log
echo old > "$log"
touch -d '40 days ago' "$log"
check "$EL" clean --dry-run
rc=0; EB_LOCAL_TRASH=none "$EL" clean || rc=$?
check test "$rc" -eq 1
check test -e "$log"
check env EB_LOCAL_TRASH=none "$EL" clean --delete
check test ! -e "$log"

echo "== development tasks on a compute node"
check env EB_LOCAL_BIN="$EL" bash "$HERE/dev-tasks.sh"

echo "passed $pass, failed $fail"
[ "$fail" -eq 0 ]
