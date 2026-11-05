       >>source format free
*> Bessel Observatory: validate input, evaluate the common midpoint integral in child processes, then save CSV.
*> The parent owns file I/O and result ordering; children perform the numerical work.
*> The common CLI accepts an input file or -, an output filename, and a worker limit from 1 to 16.
identification division.
program-id. bessel.
environment division.
input-output section.
*> Associate logical files with configurable paths and a shared status field.
file-control.
    select source-file assign to source-name
        organization line sequential file status file-status.
    select result-file assign to target-name
        organization line sequential file status file-status.
data division.
file section.
fd source-file.
01 source-line pic x(4096).
fd result-file.
01 result-line pic x(160).
working-storage section.
01 source-name pic x(4096) value "/dev/stdin".
01 target-name pic x(4096) value "results.csv".
01 file-status pic xx.
01 arg-text pic x(4096).
01 arg-count binary-long.
01 jobs binary-long value 2.
01 row-count binary-long value 0.
01 done binary-char value 0.
01 bad-worker binary-char value 0.
01 first-row binary-long.
01 last-row binary-long.
01 row-index binary-long.
01 started binary-long.
01 k binary-long.
01 rc usage binary-long.
01 child-pid usage binary-long.
01 wait-status usage binary-long.
01 byte-count usage binary-long-long.
01 io-size usage binary-long-long unsigned value 8.
01 fds.
   02 read-fd usage binary-long.
   02 write-fd usage binary-long.
01 x usage float-long.
01 y usage float-long.
01 angle usage float-long.
01 pi-value usage float-long value 3.14159265358979323846.
01 sample-pointer usage pointer.
01 sample-storage.
   02 sample-value usage float-long occurs 16384 times.
*> Reserve bounded records for each input value, numerical result and worker identity.
01 observations.
   02 observation occurs 4096 times.
      03 input-x usage float-long.
      03 result-y usage float-long.
      03 worker-pid usage binary-long.
      03 worker-fd usage binary-long.
01 printed-x pic -(4)9.9(16).
01 printed-y pic -9.9(16).
01 printed-pid pic 9(10).
linkage section.
01 current-sample usage float-long.
procedure division.
*> Coordinate CLI arguments, sequential input, process batches and CSV output.
*> Inputs: Argument registers, stdin or source-file, and shared working storage.
*> Outputs: An output file and successful status, or an error diagnostic/status.
*> Used by: The COBOL runtime when the executable starts.
main.
    *> Read positional arguments using COBOL runtime registers.
    accept arg-count from argument-number
    if arg-count > 3
        display "error: too many arguments" upon syserr
        stop run returning 1
    end-if
    if arg-count >= 1
        accept arg-text from argument-value
        evaluate function trim(arg-text)
          when "--help"
            display "Usage: bessel-cobol [INPUT|- [OUTPUT [WORKERS 1..16]]]"
            stop run returning 0
          when "-" continue
          when other move arg-text to source-name
        end-evaluate
    end-if
    if arg-count >= 2 accept target-name from argument-value end-if
    if arg-count >= 3
        accept arg-text from argument-value
        if function test-numval(arg-text) not = 0
            display "error: invalid workers" upon syserr
            stop run returning 1
        end-if
        compute x = function numval(arg-text)
        if x < 1 or x > 16 or x not = function integer(x)
            display "error: workers must be 1..16" upon syserr
            stop run returning 1
        end-if
        move x to jobs
    end-if
    if source-name = "/dev/stdin"
        display "Enter one x per line; blank line or EOF finishes:" upon syserr
    end-if
    open input source-file
    perform check-file
    *> Continue reading until EOF or an explicit blank record signals completion.
    perform until done = 1
        read source-file
        evaluate file-status
          when "10" move 1 to done
          when "00" perform accept-line
          when other perform file-error
        end-evaluate
    end-perform
    close source-file
    perform check-file
    if row-count = 0
        display "error: no valid input values" upon syserr
        stop run returning 1
    end-if
    *> Group observations so the number of simultaneously running children stays bounded.
    perform varying first-row from 1 by jobs until first-row > row-count
        compute last-row = function min(row-count, first-row + jobs - 1)
        move 0 to started bad-worker
        perform varying row-index from first-row by 1 until row-index > last-row
            call static "pipe" using by reference fds returning rc
            if rc not = 0 move 1 to bad-worker exit perform end-if
            *> Duplicate the process through GnuCOBOL while keeping the numerical kernel in COBOL.
            call "CBL_GC_FORK" returning child-pid
            *> Give the child only the compute/send/exit path; the parent continues launching workers.
            if child-pid = 0
                call static "close" using by value read-fd returning rc
                move input-x(row-index) to x
                perform calculate-j0
                call static "write" using by value write-fd
                    by reference y by value io-size returning byte-count
                call static "close" using by value write-fd returning rc
                if byte-count = 8 stop run returning 0 end-if
                stop run returning 1
            end-if
            call static "close" using by value write-fd returning rc
            if child-pid < 0
                call static "close" using by value read-fd returning rc
                move 1 to bad-worker exit perform
            end-if
            move child-pid to worker-pid(row-index)
            move read-fd to worker-fd(row-index)
            add 1 to started
        end-perform
        *> Restrict collection to children actually started if a resource failure truncated the batch.
        compute last-row = first-row + started - 1
        perform varying row-index from first-row by 1 until row-index > last-row
            call static "read" using by value worker-fd(row-index)
                by reference result-y(row-index)
                by value io-size returning byte-count
            call static "close" using by value worker-fd(row-index) returning rc
            *> Reap the child and check its exit status before trusting its result.
            call static "waitpid" using by value worker-pid(row-index)
                by reference wait-status by value 0 returning rc
            if byte-count not = 8 or wait-status not = 0 or rc not = worker-pid(row-index)
                move 1 to bad-worker
            end-if
        end-perform
        if bad-worker = 1
            display "error: worker failed" upon syserr
            stop run returning 1
        end-if
    end-perform
    *> Create output after all process batches succeed, then emit the common header and rows.
    open output result-file
    perform check-file
    move "x,j0,worker_pid" to result-line
    write result-line
    perform check-file
    perform varying row-index from 1 by 1 until row-index > row-count
        move input-x(row-index) to printed-x
        move result-y(row-index) to printed-y
        move worker-pid(row-index) to printed-pid
        move spaces to result-line
        *> Assemble comma-separated text from edited numeric fields without leading padding.
        string function trim(printed-x) "," function trim(printed-y) "," printed-pid
            into result-line end-string
        write result-line
        perform check-file
    end-perform
    close result-file
    perform check-file
    display "Wrote " row-count " observations"
    stop run returning 0.
*> Classify one input record and append a valid observation.
*> Inputs: source-line plus the shared row-count and observations table.
*> Outputs: An appended numeric value, a stop flag, or a warning for a skipped record.
*> Used by: main after a successful READ of source-file.
accept-line.
    move function trim(source-line) to arg-text
    evaluate true
      when arg-text = spaces move 1 to done
      when arg-text(1:1) = "#" continue
      when other
        if function test-numval-f(arg-text) not = 0
            display "warning: invalid number; skipped" upon syserr
        else
            compute x = function numval-f(arg-text)
                on size error move 1001 to x
            end-compute
            if x < -1000 or x > 1000
                display "warning: x outside [-1000,1000]; skipped" upon syserr
            else
                if row-count = 4096
                    display "error: at most 4096 values" upon syserr
                    stop run returning 1
                end-if
                add 1 to row-count
                move x to input-x(row-count)
            end-if
        end-if
    end-evaluate.
*> Evaluate midpoint samples and reduce them through a referenced memory view.
*> Inputs: The working-storage value x.
*> Outputs: The working-storage value y containing approximate J0.
*> Used by: The child branch of main before writing its result to the pipe.
calculate-j0.
    move 0 to y
    perform varying k from 0 by 1 until k = 16384
        compute angle = pi-value * (k + 0.5) / 16384
        compute sample-value(k + 1) = function cos(x * function sin(angle))
    end-perform
    *> POINTER arithmetic counts bytes. The LINKAGE item is a reference
    *> into sample-storage, whose lifetime covers every dereference here.
    set sample-pointer to address of sample-storage
    perform 16384 times
        set address of current-sample to sample-pointer
        compute y = y + current-sample
        set sample-pointer up by length of current-sample
    end-perform
    compute y = y / 16384.
*> Turn any unsuccessful file status into a fatal file diagnostic.
*> Inputs: The status last set by an OPEN, WRITE or CLOSE operation.
*> Outputs: Normal return for status 00; otherwise file-error terminates the run.
*> Used by: main after file operations that must succeed.
check-file.
    if file-status not = "00" perform file-error end-if.
*> Report the failing COBOL file status and stop the experiment.
*> Inputs: The shared file-status field.
*> Outputs: A stderr message and return code 1.
*> Used by: check-file and the READ loop for unexpected statuses.
file-error.
    display "error: file status " file-status upon syserr
    stop run returning 1.
