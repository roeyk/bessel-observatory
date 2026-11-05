#!/usr/bin/env bash
# Bessel Observatory: Bash 4.3+ orchestrates independent awk processes.
# Bash has integer arithmetic; awk supplies the floating-point kernel below.
# Every result carries the PID of the process that actually calculated it.
set -uo pipefail
export LC_ALL=C
declare -a values=() pids=() rows=()
temporary=''

# Report an unrecoverable error and let the EXIT trap release resources.
# Inputs: Diagnostic words. Outputs: stderr and exit status 1.
# Used by: argument, input, worker, and output checks throughout this script.
fail() { printf 'bessel: %s\n' "$*" >&2; exit 1; }

# Reap outstanding workers and remove this invocation's private row files.
# Inputs: Global pids and temporary directory. Outputs: released resources.
# Used by: EXIT and signal traps so ordinary failures leave no child jobs.
cleanup() {
    local pid
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || :; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || :; done
    [[ -z $temporary ]] || rm -rf -- "$temporary"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Trim whitespace through a nameref, illustrating Bash's reference model.
# Inputs: Name of a caller-owned string variable. Outputs: modified variable.
# Used by: the input loop before comment, blank-line, and numeric checks.
trim() {
    local -n target=$1
    target="${target#"${target%%[![:space:]]*}"}"
    target="${target%"${target##*[![:space:]]}"}"
}

# Compute one observation in the child that exec replaces with awk.
# Inputs: Decimal x and private output path. Outputs: one CSV row, or failure.
# Used by: the batch loop; BASHPID survives exec and identifies the math worker.
observe() {
    exec awk -v x="$1" -v pid="$BASHPID" '
        # Midpoint quadrature averages the oscillating Bessel integrand.
        BEGIN {
            n = 16384; pi = 4 * atan2(1, 1); sum = 0
            for (k = 0; k < n; k++) sum += cos(x * sin(pi * (k + .5) / n))
            printf "%.17g,%.17g,%d\n", x, sum / n, pid
        }
    ' > "$2"
}

# Wait for a whole bounded batch before scheduling another one.
# Inputs: Global pids. Outputs: empty pid array, or a readable fatal error.
# Used by: the scheduling loop and its final partly filled batch.
join_batch() {
    local pid failed=0
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    pids=()
    (( failed == 0 )) || fail 'a numeric worker failed'
}

# Validate the public positional interface before acquiring any resources.
if [[ $# == 1 && $1 == --help ]]; then
    printf 'Usage: bash bessel.sh [INPUT|- [OUTPUT [WORKERS]]]\n'; exit 0
fi
(( $# <= 3 )) || fail 'expected at most three arguments; use --help'
input=${1:--}; output=${2:-results.csv}; workers=${3:-2}
[[ $workers =~ ^[0-9]+$ && ${#workers} -le 2 ]] || fail 'WORKERS must be an integer from 1 to 16'
workers=$((10#$workers))
(( workers >= 1 && workers <= 16 )) || fail 'WORKERS must be from 1 to 16'
command -v awk >/dev/null || fail 'awk is required for floating-point mathematics'

# Use a dedicated descriptor so console and file input share the same loop.
if [[ $input == - ]]; then
    exec 3<&0
    [[ ! -t 0 ]] || printf 'Enter x values; blank line finishes.\n' >&2
else
    [[ -f $input && -r $input ]] || fail "cannot read $input"
    exec 3< "$input" || fail "cannot open $input"
fi
while IFS= read -r line <&3 || [[ -n $line ]]; do
    trim line
    [[ -n $line ]] || break
    # Substring offsets operate on characters; Bash has no raw address arithmetic.
    [[ ${line:0:1} != '#' ]] || continue
    if [[ ! $line =~ ^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]] ||
       ! awk -v x="$line" 'BEGIN {exit !(x+0 >= -1000 && x+0 <= 1000)}'; then
        printf 'Skipping invalid value: %s\n' "$line" >&2; continue
    fi
    (( ${#values[@]} < 4096 )) || fail 'at most 4096 observations are allowed'
    values+=("$line")
done
exec 3<&-
(( ${#values[@]} > 0 )) || fail 'no valid observations'
temporary=$(mktemp -d) || fail 'cannot create temporary directory'

# Private files avoid pipe deadlocks and preserve input order across batches.
for index in "${!values[@]}"; do
    rows+=("$temporary/$index.csv")
    observe "${values[index]}" "${rows[index]}" &
    pids+=("$!")
    (( ${#pids[@]} < workers )) || join_batch
done
join_batch
{ printf 'x,j0,worker_pid\n' && cat -- "${rows[@]}"; } > "$output" || fail "cannot write $output"
printf 'Wrote %d observations to %s\n' "${#values[@]}" "$output"
