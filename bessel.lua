#!/usr/bin/env lua
--[[
  Bessel Observatory: read x values, compute the same midpoint integral in OS workers, and write CSV.
  The normal argument order is input file (or -), output file, then worker limit.
  User input is validated before workers start; malformed numeric lines are reported and skipped.
  Lua 5.4 + luaposix: small functions, tables, protected calls and OS pipes.
  Run the Lua edition and keep required modules inside the protected entry call.
  Inputs: The global argument table plus a file or stdin.
  Outputs: An ordered CSV and completion message; failures raise Lua errors.
  Used by: The final pcall, which turns errors into a diagnostic and exit status.
]]
local function main()
    if #arg == 1 and arg[1] == '--help' then
        print('Usage: lua bessel.lua [INPUT|- [OUTPUT [WORKERS 1..16]]]')
        return
    end
    -- Load the POSIX process bindings; a missing dependency is caught by the outer pcall.
    local unistd = require 'posix.unistd'
    local wait = require('posix.sys.wait').wait
    --[[
      Validate a string as one supported numeric observation.
      Inputs: A line token.
      Outputs: A finite Lua number in range, or an assertion error.
      Used by: The protected input-validation call inside main.
    ]]
    local function number(text)
        local x = tonumber(text)
        assert(x and x == x and math.abs(x) <= 1000, 'expected finite x in [-1000,1000]')
        return x
    end
    --[[
      Compute J0 in a worker and serialize its process identity.
      Inputs: One validated numeric value.
      Outputs: A complete CSV row.
      Used by: The child branch of the POSIX fork loop.
    ]]
    local function observe(x)
        local sum = 0
        for k = 0, 16383 do sum = sum + math.cos(x * math.sin(math.pi * (k + 0.5) / 16384)) end
        return ('%.17g,%.17g,%d\n'):format(x, sum / 16384, unistd.getpid())
    end
    assert(#arg <= 3, 'too many arguments')
    local source, target, jobs = arg[1] or '-', arg[2] or 'results.csv', tonumber(arg[3] or '2')
    assert(jobs and jobs % 1 == 0 and jobs >= 1 and jobs <= 16, 'workers must be 1..16')
    if source == '-' then io.stderr:write('Enter one x per line; blank line or EOF finishes:\n') end
    local input = source == '-' and io.stdin or assert(io.open(source, 'r'))
    local values = {}
    -- Keep a read failure recoverable long enough to close an owned file handle.
    local ok, err = pcall(function()
        for line in input:lines() do
            local text = line:match('^%s*(.-)%s*$')
            if text == '' then break end
            if text:sub(1, 1) ~= '#' then
                -- Isolate bad numeric lines from the rest of the input session.
                local valid, x = pcall(number, text)
                if valid then values[#values + 1] = x
                else io.stderr:write('warning: invalid number; skipped\n') end
            end
            assert(#values <= 4096, 'at most 4096 values')
        end
    end)
    if source ~= '-' then input:close() end
    assert(ok, err)
    assert(#values > 0, 'no valid input values')
    local rows = {'x,j0,worker_pid\n'}
    for first = 1, #values, jobs do
        local children = {}
        -- Capture batch failures while retaining the child handles needed for cleanup.
        local success, failure = pcall(function()
            for i = first, math.min(first + jobs - 1, #values) do
                local reader, writer = unistd.pipe()
                assert(reader, writer)
                local pid, why = unistd.fork()
                if not pid then unistd.close(reader); unistd.close(writer); error(why) end
                -- Run the numerical kernel only in the child and return its row through the pipe.
                if pid == 0 then
                    unistd.close(reader)
                    local worked = pcall(function()
                        local row = observe(values[i])
                        assert(unistd.write(writer, row) == #row, 'worker write failed')
                    end)
                    unistd.close(writer)
                    unistd._exit(worked and 0 or 1)
                end
                unistd.close(writer)
                children[#children + 1] = {pid = pid, fd = reader}
            end
            -- Read results in original order after every worker in this batch has started.
            for _, child in ipairs(children) do
                local row = assert(unistd.read(child.fd, 256))
                local pid, reason, status = wait(child.pid)
                child.reaped = pid ~= nil
                assert(pid and reason == 'exited' and status == 0 and #row > 0, 'worker failed')
                rows[#rows + 1] = row
            end
        end)
        for _, child in ipairs(children) do
            unistd.close(child.fd)
            -- Reap any children not already waited for before propagating a batch failure.
            if not child.reaped then wait(child.pid) end
        end
        assert(success, failure)
    end
    -- Tie output closure to lexical scope and check writes before announcing success.
    local output <close> = assert(io.open(target, 'w'))
    assert(output:write(table.concat(rows)))
    assert(output:flush())
    print(('Wrote %d observations to %s'):format(#values, target))
end
-- Keep dependency, file, argument, and worker failures behind a readable CLI error boundary.
local ok, error_message = pcall(main)
if not ok then io.stderr:write('error: ', tostring(error_message), '\n'); os.exit(1) end
