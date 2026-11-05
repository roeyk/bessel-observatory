/*
  Bessel Observatory: read x values, compute the same midpoint integral in OS workers, and write CSV.
  The normal argument order is input file (or -), output file, then worker limit.
  User input is validated before workers start; malformed numeric lines are reported and skipped.
  Java 17+: records, streams, try-with-resources, and ProcessBuilder.
*/
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.*;
import java.util.stream.IntStream;

public final class Bessel {
    record Observation(double x, double j0, long pid) {
        /*
          Serialize this immutable observation using a stable decimal locale.
          Inputs: The x, j0 and pid fields of this record.
          Outputs: One newline-terminated CSV row.
          Used by: run in worker mode when it sends a result to the parent JVM.
        */
        String csv() { return String.format(Locale.ROOT, "%.17g,%.17g,%d%n", x, j0, pid); }
    }
    /*
      Parse an entire numeric string and enforce the comparison domain.
      Inputs: Text from a file, stdin, or worker argument.
      Outputs: A finite double in [-1000,1000], or an argument exception.
      Used by: run to validate observations before computing them.
    */
    static double number(String text) {
        double x = Double.parseDouble(text.strip());
        if (!Double.isFinite(x) || Math.abs(x) > 1000)
            throw new IllegalArgumentException("expected finite x in [-1000,1000]");
        return x;
    }
    /*
      Compute J0 through a checked numeric buffer and record the worker PID.
      Inputs: One validated x value.
      Outputs: An immutable Observation with the quadrature result.
      Used by: run in the child JVM selected by --worker.
    */
    static Observation observe(double x) {
        /*
          Java exposes object references and checked byte offsets, not raw
          pointers. The buffer is shared by reference with its reading lambda.
        */
        var samples = ByteBuffer.allocate(16384 * Double.BYTES).order(ByteOrder.nativeOrder());
        IntStream.range(0, 16384).forEach(k ->
            samples.putDouble(Math.cos(x * Math.sin(Math.PI * (k + 0.5) / 16384))));
        double sum = IntStream.range(0, 16384)
            .mapToDouble(k -> samples.getDouble(k * Double.BYTES)).sum();
        return new Observation(x, sum / 16384, ProcessHandle.current().pid());
    }
    /*
      Execute help, one child calculation, or the complete parent workflow.
      Inputs: The program argument array and optional stdin.
      Outputs: CSV and console output; exceptions describe failed operations.
      Used by: main, which owns the final error-to-exit-status boundary.
    */
    static void run(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("--help")) {
            System.out.println("Usage: java Bessel [INPUT|- [OUTPUT [WORKERS 1..16]]]"); return;
        }
        if (args.length == 2 && args[0].equals("--worker")) {
            System.out.print(observe(number(args[1])).csv()); return;
        }
        if (args.length > 3) throw new IllegalArgumentException("too many arguments");
        String source = args.length > 0 ? args[0] : "-", target = args.length > 1 ? args[1] : "results.csv";
        int jobs = args.length > 2 ? Integer.parseInt(args[2]) : 2;
        if (jobs < 1 || jobs > 16) throw new IllegalArgumentException("workers must be 1..16");
        if (source.equals("-")) System.err.println("Enter one x per line; blank line or EOF finishes:");
        // Accumulate only valid observations before creating any children.
        List<Double> values = new ArrayList<>();
        // Ensure a file or stdin reader is closed even if reading fails.
        try (var input = source.equals("-") ? new BufferedReader(new InputStreamReader(System.in))
                                           : Files.newBufferedReader(Path.of(source))) {
            for (String line; (line = input.readLine()) != null;) {
                String text = line.strip();
                if (text.isEmpty()) break;
                if (text.startsWith("#")) continue;
                try { values.add(number(text)); }
                catch (IllegalArgumentException e) { System.err.println("warning: " + e.getMessage() + "; skipped"); }
                if (values.size() > 4096) throw new IllegalArgumentException("at most 4096 values");
            }
        }
        if (values.isEmpty()) throw new IllegalArgumentException("no valid input values");
        var rows = new StringBuilder("x,j0,worker_pid\n");
        String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        for (int i = 0; i < values.size(); i += jobs) {
            // Keep the complete batch alive until it has all been launched and collected.
            List<Process> children = new ArrayList<>();
            try {
                for (double x : values.subList(i, Math.min(i + jobs, values.size())))
                    // Start a separate JVM with the same classpath so it can load this program and its worker mode.
                    children.add(new ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                        "Bessel", "--worker", Double.toString(x)).redirectError(ProcessBuilder.Redirect.INHERIT).start());
                for (var child : children) {
                    // Drain the small worker payload before waiting, then check that the child exited successfully.
                    String row = new String(child.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
                    if (child.waitFor() != 0 || row.isEmpty()) throw new IOException("worker failed");
                    rows.append(row);
                }
            } finally {
                for (var child : children) {
                    // Terminate unfinished children when a batch fails and reap each process.
                    if (child.isAlive()) child.destroyForcibly();
                    child.waitFor();
                }
            }
        }
        // Publish ordered CSV only after all children have returned valid rows.
        Files.writeString(Path.of(target), rows);
        System.out.printf("Wrote %d observations to %s%n", values.size(), target);
    }
    /*
      Start the Java edition and keep ordinary failures readable.
      Inputs: The argument array supplied by the JVM.
      Outputs: A normal return on success or process status 1 on error.
      Used by: The Java launcher.
    */
    public static void main(String[] args) {
        try { run(args); }
        catch (Exception e) { System.err.println("error: " + e.getMessage()); System.exit(1); }
    }
}
