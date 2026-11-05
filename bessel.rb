#!/usr/bin/env ruby

=begin

Bessel Observatory: read numeric observations, compute J0 in child processes, and save ordered CSV.
J0 is approximated by averaging cos(x*sin(theta)) at 16,384 midpoint angles.
Normal use: PROGRAM [INPUT|- [OUTPUT [WORKERS]]]. Invalid value lines are reported and skipped.
Ruby 3.x, POSIX. Blocks own resources; child processes communicate via pipes.
Use the standard CSV writer so formatting and escaping do not depend on hand-built delimiters.

=end

require 'csv'
require 'fiddle'


=begin

Convert an input token and reject values outside the supported domain.
Inputs: A string containing one observation.
Outputs: A finite Float, or ArgumentError.
Used by: The input loop before scheduling a value for computation.

=end

def number(text)
  x = Float(text)
  raise ArgumentError, 'expected a finite x in [-1000,1000]' unless x.finite? && x.abs <= 1000
  x
end


=begin

Compute one observation and demonstrate a bounded native-memory view.
Inputs: A validated Float x.
Outputs: An array containing x, approximate J0, and the worker PID.
Used by: Each forked child in parallel_batch before it serializes its CSV row.

=end

def observe(x)
  samples = (0...16_384).map { |k| Math.cos(x * Math.sin(Math::PI * (k + 0.5) / 16_384)) }
  storage = samples.pack('d*')
  pointer = Fiddle::Pointer[storage]

=begin

Fiddle pointer addition counts bytes. Keep storage alive and unchanged;
every read is an in-bounds native double. Normal Ruby would sum samples.

=end

  width = Fiddle::SIZEOF_DOUBLE
  sum = samples.each_index.sum { |k| (pointer + k * width)[0, width].unpack1('d') }
  [x, sum / 16_384, Process.pid]
end


=begin

Start one process per value, then collect their CSV rows in the original order.
Inputs: A group of at most the requested worker count.
Outputs: An array of complete CSV rows, or an exception; pipes and children are cleaned up.
Used by: The top-level each_slice pipeline that processes the whole input.

=end

def parallel_batch(values)
  # Retain every child handle until collection or cleanup has completed.
  children = []
  begin
    values.each do |x|
      reader, writer = IO.pipe
      begin
        # The child owns the numerical calculation; the parent continues launching the batch.
        pid = fork do
          reader.close
          begin
            writer.write(CSV.generate_line(observe(x)))
            writer.close
            exit! 0
          rescue StandardError => e
            warn "worker: #{e.message}"
            exit! 1
          end
        end
      rescue Exception
        reader.close
        raise
      ensure
        writer.close
      end
      children << [pid, reader]
    end
    # Read ordered results only after every child in this batch has started.
    children.map do |pid, reader|
      row = reader.read
      _, status = Process.wait2(pid)
      raise IOError, "worker #{pid} failed" unless status.success? && !row.empty?
      row
    end
  ensure
    # Close descriptors and reap children on both normal completion and exceptions.
    children.each do |pid, reader|
      reader.close unless reader.closed?
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        # Already reaped on the normal path.
      end
    end
  end
end

begin
  if ARGV == ['--help']
    puts 'Usage: ruby bessel.rb [INPUT|- [OUTPUT [WORKERS 1..16]]]'
    exit 0
  end
  raise ArgumentError, 'too many arguments' if ARGV.size > 3
  # Apply the common defaults and interpret the optional worker count.
  source, target, jobs = ARGV.fetch(0, '-'), ARGV.fetch(1, 'results.csv'), Integer(ARGV.fetch(2, '2'))
  raise ArgumentError, 'workers must be 1..16' unless (1..16).cover?(jobs)
  warn 'Enter one x per line; blank line or EOF finishes:' if source == '-'
  input = source == '-' ? $stdin : File.open(source)
  values = []
  begin
    # Read and normalize user values while retaining useful line numbers.
    input.each_line.with_index(1) do |line, index|
      text = line.strip
      break if text.empty?
      next if text.start_with?('#')
      begin
        values << number(text)
      rescue ArgumentError => e
        warn "warning: line #{index}: #{e.message}; skipped"
      end
      raise ArgumentError, 'at most 4096 values' if values.size > 4096
    end
  ensure
    input.close unless input.equal?($stdin)
  end
  raise ArgumentError, 'no valid input values' if values.empty?
  # Finish bounded groups of children and flatten their ordered results.
  rows = values.each_slice(jobs).flat_map { |batch| parallel_batch(batch) }
  # Write the complete CSV in a scoped file block so closure happens automatically.
  File.open(target, 'w') { |file| file.write("x,j0,worker_pid\n"); rows.each { |row| file.write(row) } }
  puts "Wrote #{rows.size} observations to #{target}"
# Keep ordinary runtime failures readable instead of displaying a Ruby backtrace.
rescue StandardError => e
  warn "error: #{e.message}"
  exit 1
rescue Interrupt
  warn 'error: interrupted'
  exit 130
end
