#!/usr/bin/env julia
#=
  Bessel Observatory: read x values, compute the same midpoint integral in OS workers, and write CSV.
  The normal argument order is input file (or -), output file, then worker limit.
  User input is validated before workers start; malformed numeric lines are reported and skipped.
  Julia 1.10+: multiple dispatch, Distributed.pmap, do-blocks, named tuples.
=#
using Distributed
using Printf

#=
  Evaluate one observation and identify the Julia worker process.
  Inputs: A validated Float64 x.
  Outputs: A named tuple containing x, approximate J0 and the OS PID.
  Used by: Distributed.pmap in main to perform work in separate processes.
=#
function observe(x::Float64)
    samples = [cos(x * sinpi((k + 0.5) / 16384)) for k in 0:16383]
    #=
      Ptr arithmetic is in bytes. Preserve the owner while raw pointers exist;
      the byte offsets below stay aligned and within the Float64 array.
    =#
    s = GC.@preserve samples begin
        base = pointer(samples)
        sum(unsafe_load(base + (k - 1) * sizeof(Float64)) for k in eachindex(samples))
    end
    (x=x, j0=s / 16384, pid=getpid())
end

#=
  Interpret and validate one numeric token.
  Inputs: An AbstractString from the input reader.
  Outputs: A finite Float64 in range, or an ArgumentError.
  Used by: readvalues, which can skip individual malformed lines.
=#
function number(text::AbstractString)
    x = parse(Float64, strip(text))
    isfinite(x) && abs(x) <= 1000 || throw(ArgumentError("expected finite x in [-1000,1000]"))
    x
end

#=
  Read accepted observations while preserving their sequence.
  Inputs: An IO stream such as stdin or an open file.
  Outputs: A nonempty Float64 vector, or a fatal input error.
  Used by: main before it creates Distributed workers.
=#
function readvalues(io::IO)
    values = Float64[]
    # Classify each line as a terminator, comment, or candidate observation.
    for line in eachline(io)
        text = strip(line)
        isempty(text) && break
        startswith(text, '#') && continue
        try
            push!(values, number(text))
        catch e
            # Recover only from expected numeric-input errors; preserve other failures.
            e isa ArgumentError || rethrow()
            println(stderr, "warning: ", sprint(showerror, e), "; skipped")
        end
        length(values) <= 4096 || error("at most 4096 values")
    end
    isempty(values) && error("no valid input values")
    values
end

#=
  Run the CLI, start worker processes, gather observations and save CSV.
  Inputs: The argument vector and optional user input.
  Outputs: A completed result file; errors propagate after workers are removed.
  Used by: The guarded script entry block at the bottom of the file.
=#
function main(args)
    if args == ["--help"]
        println("Usage: julia bessel.jl [INPUT|- [OUTPUT [WORKERS 1..16]]]")
        return
    end
    length(args) <= 3 || error("too many arguments")
    source = get(args, 1, "-"); target = get(args, 2, "results.csv")
    jobs = parse(Int, get(args, 3, "2"))
    1 <= jobs <= 16 || error("workers must be 1..16")
    values = if source == "-"
        println(stderr, "Enter one x per line; blank line or EOF finishes:")
        readvalues(stdin)
    else
        open(readvalues, source)
    end
    # Create real worker processes rather than Julia tasks in the parent process.
    pids = addprocs(jobs)
    try
        #=
          Load definitions in each OS worker; the PROGRAM_FILE guard prevents
          the CLI from running recursively when this source is included.
        =#
        @everywhere pids include($(abspath(@__FILE__)))
        # Keep the output order tied to the input vector even when worker completion order differs.
        rows = pmap(observe, WorkerPool(pids), values)
        # Scope the output file and serialize the named fields of each completed observation.
        open(target, "w") do io
            println(io, "x,j0,worker_pid")
            for row in rows
                @printf(io, "%.17g,%.17g,%d\n", row.x, row.j0, row.pid)
            end
        end
        println("Wrote $(length(rows)) observations to $target")
    finally
        # Remove the processes created for this run, including when loading or computation fails.
        rmprocs(pids)
    end
end

# Run the CLI only for direct execution; worker include calls should define functions without prompting.
if abspath(PROGRAM_FILE) == @__FILE__
    try
        main(ARGS)
    catch e
        println(stderr, "error: ", sprint(showerror, e))
        exit(1)
    end
end
