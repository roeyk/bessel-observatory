/*
  Bessel Observatory: read x values, compute the same midpoint integral in OS workers, and write CSV.
  The normal argument order is input file (or -), output file, then worker limit.
  User input is validated before workers start; malformed numeric lines are reported and skipped.
  Kotlin 1.9+, JVM 17: data classes, when, collection pipelines, use and finally.
*/
import java.io.File
import java.util.Locale
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.*

data class Observation(val x: Double, val j0: Double, val pid: Long) {
    /*
      Format this observation independently of the machine locale.
      Inputs: The fields of the current Observation value.
      Outputs: A single CSV row ending in a newline.
      Used by: run in child mode to send a result to the parent.
    */
    fun csv() = String.format(Locale.ROOT, "%.17g,%.17g,%d\n", x, j0, pid)
}
/*
  Convert a token and validate its range in one expression.
  Inputs: A string from input or an internal worker argument.
  Outputs: A finite Double, or an argument/conversion exception.
  Used by: run while accepting input and computing child results.
*/
fun number(text: String): Double = text.trim().toDouble().also {
    require(it.isFinite() && abs(it) <= 1000) { "expected finite x in [-1000,1000]" }
}
/*
  Compute the Bessel integral using shared, checked buffer views.
  Inputs: One validated Double x.
  Outputs: An Observation value including the OS process identifier.
  Used by: run when this JVM has been launched as a worker.
*/
fun observe(x: Double): Observation {
    // JVM references plus checked byte-offset arithmetic; no raw pointers.
    val samples = ByteBuffer.allocate(16384 * java.lang.Double.BYTES).order(ByteOrder.nativeOrder())
    (0 until 16384).forEach { k -> samples.putDouble(cos(x * sin(PI * (k + 0.5) / 16384))) }
    val sum = (0 until 16384).sumOf { k -> samples.getDouble(k * java.lang.Double.BYTES) }
    return Observation(x, sum / 16384, ProcessHandle.current().pid())
}

/*
  Launch a bounded group of JVMs and gather their CSV rows.
  Inputs: An ordered list of validated x values.
  Outputs: Rows in input order; exceptions propagate after process cleanup.
  Used by: run through chunked(jobs).flatMap to handle the full input.
*/
fun batch(values: List<Double>): List<String> {
    val children = mutableListOf<Process>()
    try {
        values.forEach { x ->
            // Reuse the current JVM classpath so the child can find both this class and Kotlin runtime classes.
            children += ProcessBuilder(
                File(System.getProperty("java.home"), "bin/java").path,
                "-cp", System.getProperty("java.class.path"), "BesselKt", "--worker", x.toString()
            ).redirectError(ProcessBuilder.Redirect.INHERIT).start()
        }
        // Read results only after every child in this group has been started.
        return children.map { child ->
            val row = child.inputStream.bufferedReader().use { it.readText() }
            check(child.waitFor() == 0 && row.isNotEmpty()) { "worker failed" }
            row
        }
    } finally {
        // Ensure early failures do not leave uncollected workers.
        children.forEach { child ->
            if (child.isAlive) child.destroyForcibly()
            child.waitFor()
        }
    }
}
/*
  Implement the parent CLI and the internal single-value worker mode.
  Inputs: Command-line argument strings and optional stdin.
  Outputs: A result file and completion message, or an exception.
  Used by: main, which translates exceptions into a failure exit.
*/
fun run(args: Array<String>) {
    when {
        args.contentEquals(arrayOf("--help")) -> {
            println("Usage: java -jar bessel-kotlin.jar [INPUT|- [OUTPUT [WORKERS 1..16]]]")
            return
        }
        args.size == 2 && args[0] == "--worker" -> { print(observe(number(args[1])).csv()); return }
    }
    require(args.size <= 3) { "too many arguments" }
    val source = args.getOrElse(0) { "-" }
    val target = args.getOrElse(1) { "results.csv" }
    val jobs = args.getOrElse(2) { "2" }.toInt()
    require(jobs in 1..16) { "workers must be 1..16" }
    if (source == "-") System.err.println("Enter one x per line; blank line or EOF finishes:")
    val input = if (source == "-") System.`in`.bufferedReader() else File(source).bufferedReader()
    val values = mutableListOf<Double>()
    // Keep input ownership scoped to the reading phase.
    input.use { reader ->
        for (line in reader.lineSequence()) {
            val text = line.trim()
            // Choose termination, comment skipping, or recoverable numeric validation.
            when {
                text.isEmpty() -> break
                text.startsWith('#') -> continue
                else -> try { values += number(text) }
                    catch (e: IllegalArgumentException) { System.err.println("warning: ${e.message}; skipped") }
            }
            require(values.size <= 4096) { "at most 4096 values" }
        }
    }
    require(values.isNotEmpty()) { "no valid input values" }
    // Limit concurrency with chunks while retaining collection order.
    val rows = values.chunked(jobs).flatMap(::batch)
    // Scope the output file and write its header followed by all completed observations.
    File(target).bufferedWriter().use { output ->
        output.write("x,j0,worker_pid\n"); rows.forEach(output::write)
    }
    println("Wrote ${rows.size} observations to $target")
}
/*
  Provide Kotlin executable startup with a readable error boundary.
  Inputs: The JVM argument array.
  Outputs: Normal return on success or process status 1 after a diagnostic.
  Used by: The generated BesselKt launcher class.
*/
fun main(args: Array<String>) {
    try { run(args) }
    catch (e: Exception) { System.err.println("error: ${e.message}"); kotlin.system.exitProcess(1) }
}
