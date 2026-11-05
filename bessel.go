/*
  Bessel Observatory: read x values, compute the same midpoint integral in OS workers, and write CSV.
  The normal argument order is input file (or -), output file, then worker limit.
  User input is validated before workers start; malformed numeric lines are reported and skipped.
  Go 1.22+: explicit errors, defer, and os/exec. Math runs in OS children.
*/
package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"unsafe"
)

/*
  Parse one token and apply the common domain restrictions.
  Inputs: A numeric string.
  Outputs: A float64 plus nil error, or a descriptive error.
  Used by: readValues and the internal worker branch of run.
*/
func number(text string) (float64, error) {
	x, err := strconv.ParseFloat(strings.TrimSpace(text), 64)
	if err != nil || math.IsNaN(x) || math.IsInf(x, 0) || math.Abs(x) > 1000 {
		return 0, errors.New("expected finite x in [-1000,1000]")
	}
	return x, nil
}
/*
  Build midpoint samples and sum them through a bounded pointer walk.
  Inputs: One validated float64 x.
  Outputs: The approximate J0 value.
  Used by: run in the separate OS process selected by --worker.
*/
func observe(x float64) float64 {
	samples := make([]float64, 16384)
	for k := range samples {
		samples[k] = math.Cos(x * math.Sin(math.Pi*(float64(k)+0.5)/16384))
	}
	sum := 0.0
	base := unsafe.Pointer(unsafe.SliceData(samples))
	/*
	  Educational raw-pointer walk. Every offset stays inside this live,
	  aligned allocation; normal Go would simply range over the slice.
	*/
	for k := range samples {
		sum += *(*float64)(unsafe.Add(base, uintptr(k)*unsafe.Sizeof(samples[0])))
	}
	runtime.KeepAlive(samples)
	return sum / 16384
}
/*
  Read normalized observations through a generic input interface.
  Inputs: Any io.Reader, normally stdin or an opened file.
  Outputs: An ordered nonempty slice of values, or an input error.
  Used by: run before it starts any worker process.
*/
func readValues(input io.Reader) ([]float64, error) {
	// Stream input line by line and retain scanner errors instead of treating them as normal EOF.
	scanner := bufio.NewScanner(input)
	var values []float64
	for scanner.Scan() {
		text := strings.TrimSpace(scanner.Text())
		if text == "" {
			break
		}
		if strings.HasPrefix(text, "#") {
			continue
		}
		x, err := number(text)
		if err != nil {
			fmt.Fprintln(os.Stderr, "warning:", err, "; skipped")
			continue
		}
		values = append(values, x)
		if len(values) > 4096 {
			return nil, errors.New("at most 4096 values")
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(values) == 0 {
		return nil, errors.New("no valid input values")
	}
	return values, nil
}
/*
  Start all children for one bounded group before waiting for results.
  Inputs: This executable path and the group of input values.
  Outputs: Concatenated CSV rows, or an error after child cleanup.
  Used by: run once per worker-sized slice.
*/
func batch(executable string, values []float64) ([]byte, error) {
	type worker struct {
		command *exec.Cmd
		output  bytes.Buffer
		reaped  bool
	}
	children := make([]*worker, 0, len(values))
	// Keep cleanup tied to batch scope so a failed start or wait cannot orphan the owned workers.
	defer func() {
		for _, child := range children {
			if !child.reaped {
				_ = child.command.Process.Kill()
				_ = child.command.Wait()
			}
		}
	}()
	for _, x := range values {
		child := &worker{command: exec.Command(executable, "--worker", strconv.FormatFloat(x, 'g', -1, 64))}
		// Give each child its own byte buffer so concurrent output cannot mix.
		child.command.Stdout = &child.output
		child.command.Stderr = os.Stderr
		// Launch without waiting, allowing the rest of this batch to run concurrently.
		if err := child.command.Start(); err != nil {
			return nil, fmt.Errorf("start worker: %w", err)
		}
		children = append(children, child)
	}
	var rows bytes.Buffer
	for _, child := range children {
		// Finish the child and its output-copying goroutines before accessing the result buffer.
		err := child.command.Wait()
		child.reaped = true
		if err != nil {
			return nil, fmt.Errorf("worker: %w", err)
		}
		if child.output.Len() == 0 {
			return nil, errors.New("empty worker result")
		}
		rows.Write(child.output.Bytes())
	}
	return rows.Bytes(), nil
}
/*
  Perform help, a single worker calculation, or the full experiment.
  Inputs: Program argument strings and the process input/output environment.
  Outputs: nil on success or an error describing the failed operation.
  Used by: main, which reports the error and chooses the exit status.
*/
func run(args []string) error {
	if len(args) == 1 && args[0] == "--help" {
		fmt.Println("Usage: bessel-go [INPUT|- [OUTPUT [WORKERS 1..16]]]")
		return nil
	}
	if len(args) == 2 && args[0] == "--worker" {
		x, err := number(args[1])
		if err != nil {
			return err
		}
		_, err = fmt.Printf("%.17g,%.17g,%d\n", x, observe(x), os.Getpid())
		return err
	}
	if len(args) > 3 {
		return errors.New("too many arguments")
	}
	source, target, jobs := "-", "results.csv", 2
	if len(args) > 0 {
		source = args[0]
	}
	if len(args) > 1 {
		target = args[1]
	}
	if len(args) > 2 {
		var err error
		jobs, err = strconv.Atoi(args[2])
		if err != nil {
			return err
		}
	}
	if jobs < 1 || jobs > 16 {
		return errors.New("workers must be 1..16")
	}
	input := os.Stdin
	if source == "-" {
		fmt.Fprintln(os.Stderr, "Enter one x per line; blank line or EOF finishes:")
	} else {
		var err error
		input, err = os.Open(source)
		if err != nil {
			return err
		}
		defer input.Close()
	}
	// Complete validation before creating child processes or the result file.
	values, err := readValues(input)
	if err != nil {
		return err
	}
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	var rows bytes.Buffer
	rows.WriteString("x,j0,worker_pid\n")
	for i := 0; i < len(values); i += jobs {
		end := i + jobs
		if end > len(values) {
			end = len(values)
		}
		result, err := batch(executable, values[i:end])
		if err != nil {
			return err
		}
		rows.Write(result)
	}
	// Write the assembled CSV once numerical work has succeeded.
	if err := os.WriteFile(target, rows.Bytes(), 0644); err != nil {
		return err
	}
	fmt.Printf("Wrote %d observations to %s\n", len(values), target)
	return nil
}
/*
  Expose the command-line entry point and final error reporting.
  Inputs: os.Args after the executable name.
  Outputs: Console diagnostics and a nonzero exit if run fails.
  Used by: The Go runtime when the executable starts.
*/
func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
