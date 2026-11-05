/*
  Bessel Observatory: read x values, compute the same midpoint integral in OS workers, and write CSV.
  The normal argument order is input file (or -), output file, then worker limit.
  User input is validated before workers start; malformed numeric lines are reported and skipped.
  Swift 5.9+, Foundation. Typed errors, value types, defer, Process and Pipe.
*/
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ObservatoryError: Error, CustomStringConvertible {
    case invalid(String)
    /*
      Turn a typed application error into its user-facing explanation.
      Inputs: The message associated with this ObservatoryError value.
      Outputs: A readable String.
      Used by: Error reporting through warn at the entry boundary.
    */
    var description: String { switch self { case .invalid(let message): return message } }
}
/*
  Send one diagnostic line to standard error.
  Inputs: The text to display.
  Outputs: No value; stderr receives UTF-8 text and a newline.
  Used by: Input validation and the final error handler.
*/
func warn(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
/*
  Convert an input token and reject unsupported values.
  Inputs: A String from a line or worker argument.
  Outputs: A finite Double in range, or ObservatoryError.
  Used by: The accept helper and the internal worker branch of main.
*/
func number(_ text: String) throws -> Double {
    guard let x = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), x.isFinite, abs(x) <= 1000
    else { throw ObservatoryError.invalid("expected finite x in [-1000,1000]") }
    return x
}
struct Observation {
    let x: Double
    /*
      Compute this observation and serialize its worker identity.
      Inputs: The x stored in the Observation struct.
      Outputs: One CSV row containing x, J0 and the current OS PID.
      Used by: main when a child process is assigned one value.
    */
    var csv: String {
        let samples = (0..<16384).map { cos(x * sin(Double.pi * (Double($0) + 0.5) / 16384)) }
        /*
          The buffer owns the memory for this closure; advanced(by:) counts
          Double elements, and every dereference is within its bounds.
        */
        let sum = samples.withUnsafeBufferPointer { buffer in
            (0..<buffer.count).reduce(0.0) { total, k in
                total + buffer.baseAddress!.advanced(by: k).pointee
            }
        }
        return "\(x),\(sum / 16384),\(ProcessInfo.processInfo.processIdentifier)\n"
    }
}
/*
  Coordinate CLI selection, input collection, worker batches and output.
  Inputs: CommandLine.arguments and optional stdin.
  Outputs: A result file and completion message; failures are thrown.
  Used by: The final do/catch entry block.
*/
func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] {
        print("Usage: bessel-swift [INPUT|- [OUTPUT [WORKERS 1..16]]]"); return
    }
    if args.count == 2 && args[0] == "--worker" {
        print(Observation(x: try number(args[1])).csv, terminator: ""); return
    }
    guard args.count <= 3 else { throw ObservatoryError.invalid("too many arguments") }
    let source = args.count > 0 ? args[0] : "-"
    let target = args.count > 1 ? args[1] : "results.csv"
    guard let jobs = Int(args.count > 2 ? args[2] : "2"), (1...16).contains(jobs)
    else { throw ObservatoryError.invalid("workers must be 1..16") }
    var values = [Double]()
    /*
      Classify one user line and append a valid observation to the enclosing list.
      Inputs: One line plus the values array captured from main.
      Outputs: false to stop input, true to continue; fatal size-limit violations throw.
      Used by: Both the interactive and file-input loops in main.
    */
    func accept(_ line: String) throws -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if text.hasPrefix("#") { return true }
        do { values.append(try number(text)) }
        catch { warn("warning: \(error); skipped") }
        guard values.count <= 4096 else { throw ObservatoryError.invalid("at most 4096 values") }
        return true
    }
    if source == "-" {
        warn("Enter one x per line; blank line or EOF finishes:")
        // Accept interactive values until the user supplies a blank line or EOF.
        while let line = readLine() { if try !accept(line) { break } }
    } else {
        for line in try String(contentsOfFile: source, encoding: .utf8).components(separatedBy: "\n") {
            if try !accept(line) { break }
        }
    }
    guard !values.isEmpty else { throw ObservatoryError.invalid("no valid input values") }
    var rows = "x,j0,worker_pid\n"
    // Partition observations into bounded process groups while preserving order.
    for start in stride(from: 0, to: values.count, by: jobs) {
        var children = [(Process, Pipe)]()
        // Tie every started child to this batch scope, including error paths.
        defer { for (child, _) in children { if child.isRunning { child.terminate() }; child.waitUntilExit() } }
        for x in values[start..<min(start + jobs, values.count)] {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--worker", String(x)]
            child.standardInput = FileHandle.nullDevice
            child.standardOutput = pipe
            // Launch the numerical worker before proceeding to the next child in the batch.
            try child.run(); children.append((child, pipe))
        }
        for (child, pipe) in children {
            // Drain the result pipe, wait for termination, and reject incomplete or failed workers.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, let row = String(data: data, encoding: .utf8), !row.isEmpty
            else { throw ObservatoryError.invalid("worker failed") }
            rows += row
        }
    }
    // Replace the output atomically after the complete CSV has been assembled.
    try rows.write(toFile: target, atomically: true, encoding: .utf8)
    print("Wrote \(values.count) observations to \(target)")
}
// Convert thrown errors into one readable diagnostic and a failure exit.
do { try main() } catch { warn("error: \(error)"); exit(1) }
