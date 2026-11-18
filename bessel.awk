#!/usr/bin/gawk -f
# Bessel Observatory — GNU Awk 5.2+ on POSIX, with real coprocess workers.
# Run: gawk -f bessel.awk -- [INPUT|- [OUTPUT [WORKERS]]]
# GNU |&, PROCINFO, nonfatal output and read timeouts are explicit dependencies.
# The shell only launches/terminates workers; mathematics and scheduling are Awk.

# Validate decimal input before Awk's otherwise permissive numeric coercion.
# Input: trimmed text. Output: true for a finite number in [-1000,1000].
# Callers: read_values, worker_main and collect check input/protocol numbers.
function number(text,    value) {
    if (text !~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/)
        return 0
    value = text + 0
    return value >= -1000 && value <= 1000
}

# Quote one POSIX shell argument, including literal single quotes in filenames.
# Input: arbitrary text. Output: a single shell word. Caller: start_workers.
function shell_quote(text,    quoted, position) {
    quoted = "'"
    while ((position = index(text, "'")) > 0) {
        quoted = quoted substr(text, 1, position - 1) "'\\''"
        text = substr(text, position + 1)
    }
    return quoted text "'"
}

# Locate the source file in the interpreter's original arguments before ARGV edits.
# Input: PROCINFO argv. Output: one -f/--file source path, or a diagnostic exit.
# Caller: main before launching the same source, including from another directory.
function program_file(    idx, arg, path, count) {
    for (idx = 1; idx in PROCINFO["argv"]; idx++) {
        arg = PROCINFO["argv"][idx]
        if (arg == "--") break
        if (arg == "-f" || arg == "--file") {
            path = PROCINFO["argv"][++idx]
            count++
        } else if (arg ~ /^--file=/) {
            path = substr(arg, 8)
            count++
        } else if (arg ~ /^-f./) {
            path = substr(arg, 3)
            count++
        }
    }
    if (count != 1 || path == "" || path == "-")
        fail("launch with one source file: gawk -f bessel.awk -- [arguments]")
    return path
}

# Report a fatal contract/I/O/protocol problem; END releases remaining workers.
# Input: message. Output: stderr diagnostic and status 1. Callers: checked operations.
function fail(message) {
    print "error: " message > "/dev/stderr"
    exit 1
}

# Read observations into an Awk-owned associative array with ordered numeric keys.
# Inputs: filename or -, borrowed array. Output: accepted count; fatal errors exit.
# Caller: main. Array parameters alias caller storage; scalars are passed by value.
function read_values(source, values,    input, line, rc, count, line_number) {
    input = source == "-" ? "/dev/stdin" : source
    if (source == "-")
        print "Enter one x per line; blank line or EOF finishes:" > "/dev/stderr"
    while ((rc = (getline line < input)) > 0) {
        line_number++
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line == "") break
        if (line ~ /^#/) continue
        if (!number(line)) {
            printf "warning: line %d: invalid value; skipped\n", line_number > "/dev/stderr"
            continue
        }
        if (count == 4096) fail("at most 4096 values are allowed")
        values[++count] = line + 0
    }
    if (rc < 0) fail("cannot read input: " ERRNO)
    if (close(input) != 0) fail("cannot close input: " ERRNO)
    if (!count) fail("no valid input values")
    return count
}

# Approximate J0 using 16384 midpoint terms and compensated summation.
# Input: validated x. Output: numeric J0. Caller: worker_main in each OS child.
# Local scalars/indices are Awk-managed values; there is no raw-pointer arithmetic.
function observe(x,    idx, term, adjusted, updated, total, correction) {
    for (idx = 0; idx < samples; idx++) {
        term = cos(x * sin(pi * (idx + 0.5) / samples))
        adjusted = term - correction
        updated = total + adjusted
        correction = (updated - total) - adjusted
        total = updated
    }
    return total / samples
}

# Run the child protocol and flush each result before reading another request.
# Input: index TAB x on stdin. Output: READY, indexed CSV rows, then DONE at EOF.
# Caller: BEGIN's --worker mode; PROCINFO supplies the actual child/parent PIDs.
function worker_main(    line, fields, rc, count) {
    ERRNO = ""
    printf "READY %d %d\n", PROCINFO["pid"], PROCINFO["ppid"]
    if (fflush() != 0 || ERRNO != "") fail("cannot send worker greeting")
    while ((rc = (getline line)) > 0) {
        if (split(line, fields, "\t") != 2 || fields[1] !~ /^[1-9][0-9]*$/ ||
            fields[1] + 0 > 4096 || !number(fields[2]) || ++count > 4096)
            fail("invalid worker request")
        ERRNO = ""
        printf "%d,%.17g,%.17g,%d\n", fields[1], fields[2] + 0,
            observe(fields[2] + 0), PROCINFO["pid"]
        if (fflush() != 0 || ERRNO != "") fail("cannot send worker result")
    }
    if (rc < 0) fail("cannot read worker input: " ERRNO)
    ERRNO = ""
    printf "DONE %d\n", count
    if (fflush() != 0 || ERRNO != "") fail("cannot send worker completion")
}

# Launch distinct two-way pipes to the same interpreter/source, using shell exec.
# Inputs: worker count and source. Output: global ownership maps of commands/PIDs.
# Caller: main. The shell becomes the Awk child; it performs no numerical work.
function start_workers(count, source,    slot, command, line, fields, rc) {
    for (slot = 1; slot <= count; slot++) {
        command = "LC_ALL=C exec " shell_quote(PROCINFO["argv"][0]) \
            " -f " shell_quote(source) " -- --worker " slot
        commands[slot] = command
        PROCINFO[command, "NONFATAL"] = 1
        PROCINFO[command, "READ_TIMEOUT"] = 60000
        ERRNO = ""
        rc = (command |& getline line)
        if (rc != 1 || split(line, fields, " ") != 3 || fields[1] != "READY" ||
            fields[2] !~ /^[1-9][0-9]*$/ || fields[2] + 0 > 2147483647 ||
            fields[3] !~ /^[1-9][0-9]*$/ || fields[3] + 0 != PROCINFO["pid"] ||
            fields[2] + 0 == PROCINFO["pid"])
            fail("worker startup failed: " ERRNO)
        pids[slot] = fields[2] + 0
    }
}

# Validate a child's indexed response and retain its public CSV record in order.
# Inputs: slot/idx, values and rows arrays. Output: one result entry, or fatal exit.
# Caller: calculate after dispatching one outstanding observation per worker.
function collect(slot, idx, values, rows,    command, line, fields, rc) {
    command = commands[slot]
    ERRNO = ""
    rc = (command |& getline line)
    if (rc != 1 || split(line, fields, ",") != 4 || fields[1] !~ /^[1-9][0-9]*$/ ||
        fields[1] + 0 != idx || !number(fields[2]) || fields[2] + 0 != values[idx] ||
        !number(fields[3]) || fields[3] + 0 < -1.0000000001 || fields[3] + 0 > 1.0000000001 ||
        fields[4] !~ /^[1-9][0-9]*$/ || fields[4] + 0 != pids[slot])
        fail("missing or invalid result from worker " slot ": " ERRNO)
    # Remove only the private index, preserving round-trip decimal precision.
    sub(/^[^,]*,/, "", line)
    rows[idx] = line
}

# Dispatch bounded rounds with one request in flight per child to prevent deadlock.
# Inputs: values/count/worker bound and rows array. Output: all ordered CSV rows.
# Caller: main; Awk owns these arrays and reclaims their storage at process exit.
function calculate(values, count, workers, rows,    first, slot, idx, command) {
    for (first = 1; first <= count; first += workers) {
        for (slot = 1; slot <= workers && first + slot - 1 <= count; slot++) {
            idx = first + slot - 1
            command = commands[slot]
            ERRNO = ""
            printf "%d\t%.17g\n", idx, values[idx] |& command
            if (ERRNO != "") fail("cannot send worker request: " ERRNO)
            sent[slot]++
        }
        for (slot = 1; slot <= workers && first + slot - 1 <= count; slot++)
            collect(slot, first + slot - 1, values, rows)
    }
}

# Send EOF, validate completion/counts and child exit statuses, and reap workers.
# Input: command map. Output: no live children on success, or a diagnostic exit.
# Caller: main before output creation. close waits for the child's exit status.
function finish_workers(    slot, command, line, fields, rc) {
    for (slot in commands) {
        command = commands[slot]
        if (close(command, "to") != 0) fail("cannot close worker input")
        rc = (command |& getline line)
        if (rc != 1 || split(line, fields, " ") != 2 || fields[1] != "DONE" ||
            fields[2] !~ /^[0-9]+$/ || fields[2] + 0 != sent[slot])
            fail("invalid worker completion")
        if ((command |& getline line) != 0) fail("extra worker output or read error")
        rc = close(command)
        delete commands[slot]
        delete pids[slot]
        if (rc != 0) fail("worker exited unsuccessfully: " rc)
    }
}

# Write completed results, checking immediate writes and delayed close errors.
# Inputs: target, rows/count. Output: CSV or a diagnostic; output is not transactional.
# Caller: main after all successful child exits. Earlier failures preserve output.
function write_results(target, rows, count,    idx) {
    # Make a bare '-' an ordinary filename rather than an interpreter stream alias.
    if (target !~ /\//) target = "./" target
    ERRNO = ""
    print "x,j0,worker_pid" > target
    if (ERRNO != "") fail("cannot open output: " ERRNO)
    for (idx = 1; idx <= count; idx++) {
        ERRNO = ""
        print rows[idx] > target
        if (ERRNO != "") fail("cannot write output: " ERRNO)
    }
    ERRNO = ""
    if (fflush(target) != 0 || ERRNO != "") fail("cannot flush output: " ERRNO)
    ERRNO = ""
    if (close(target) != 0 || ERRNO != "") fail("cannot close output: " ERRNO)
}

# Perform the entire CLI in BEGIN, avoiding implicit filename/assignment processing.
# Inputs: ARGV and optional stdin. Output: CSV, messages and exit status.
# Caller: gawk at startup; the private worker mode never creates more workers.
BEGIN {
    samples = 16384
    pi = atan2(0, -1)
    PROCINFO["NONFATAL"] = 1
    if (ARGC == 3 && ARGV[1] == "--worker") {
        ARGC = 1
        worker_main()
        exit 0
    }
    if (ARGC == 2 && ARGV[1] == "--help") {
        print "Usage: gawk -f bessel.awk -- [INPUT|- [OUTPUT [WORKERS]]]"
        print "Defaults: stdin, results.csv, 2 workers (range 1-16)."
        exit 0
    }
    if (ARGC > 4) fail("too many arguments; use --help")
    input_path = ARGC > 1 ? ARGV[1] : "-"
    output_path = ARGC > 2 ? ARGV[2] : "results.csv"
    workers = ARGC > 3 ? ARGV[3] : "2"
    if (workers !~ /^[0-9]+$/ || workers + 0 < 1 || workers + 0 > 16)
        fail("workers must be an integer from 1 through 16")
    source_path = program_file()
    ARGC = 1
    count = read_values(input_path, values)
    if (workers > count) workers = count
    start_workers(workers, source_path)
    calculate(values, count, workers, rows)
    finish_workers()
    write_results(output_path, rows, count)
    printf "Wrote %d observations to %s\n", count, output_path
    exit 0
}

# Stop/reap remaining children after ordinary failures; success empties the maps.
# Input: owned commands/PIDs. Output: child termination and reaping.
# Caller: gawk on exit. Parent signals/fatal interpreter errors are not intercepted.
END {
    for (slot in commands)
        if (slot in pids)
            system("kill -KILL " sprintf("%d", pids[slot]) " 2>/dev/null")
    for (slot in commands)
        close(commands[slot])
}
