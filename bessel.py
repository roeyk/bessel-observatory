#!/usr/bin/env python3
# Bessel Observatory: read numeric observations, compute J0 in child processes, and save ordered CSV.
# J0 is approximated by averaging cos(x*sin(theta)) at 16,384 midpoint angles.
# Normal use: PROGRAM [INPUT|- [OUTPUT [WORKERS]]]. Invalid value lines are reported and skipped.
# Bessel Observatory — Python 3.10+, standard library only.
from __future__ import annotations

import argparse
import csv
import ctypes
import math
import multiprocessing
import os
import sys
from concurrent.futures import ProcessPoolExecutor
from contextlib import nullcontext
from pathlib import Path

# Fix the quadrature resolution so results can be compared across languages.
SAMPLES = 16_384


# Parse and validate one observation without performing any computation.
# Inputs: A numeric token from an input line.
# Outputs: A finite float in [-1000,1000], or ValueError.
# Used by: read_values to reject individual malformed observations.
def number(text: str) -> float:
    value = float(text)
    if not math.isfinite(value) or abs(value) > 1_000:
        raise ValueError("expected a finite number in [-1000, 1000]")
    return value


# Calculate one Bessel observation inside a pool worker.
# Inputs: One validated x value.
# Outputs: The original x, its approximate J0, and the worker OS process ID.
# Used by: ProcessPoolExecutor.map in main to distribute the numerical work.
def observe(x: float) -> tuple[float, float, int]:
    # Midpoint quadrature, with a deliberately small ctypes memory example.
    terms = (math.cos(x * math.sin(math.pi * (k + 0.5) / SAMPLES))
             for k in range(SAMPLES))
    samples = (ctypes.c_double * SAMPLES)(*terms)
    # byref supplies a borrowed reference at a BYTE offset. The owning array
    # stays alive, and every offset is aligned and within its allocation.
    width = ctypes.sizeof(ctypes.c_double)
    values = (ctypes.cast(ctypes.byref(samples, k * width),
                          ctypes.POINTER(ctypes.c_double)).contents.value
              for k in range(SAMPLES))
    return x, math.fsum(values) / SAMPLES, os.getpid()


# Collect usable input values while allowing the user to recover from bad lines.
# Inputs: A filename or - for standard input.
# Outputs: An ordered nonempty list of at most 4096 floats; fatal input problems raise.
# Used by: main before it starts workers or creates the output file.
def read_values(source: str) -> list[float]:
    values: list[float] = []
    if source == "-":
        print("Enter one x per line; blank line or EOF finishes:", file=sys.stderr)
    context = nullcontext(sys.stdin) if source == "-" else Path(source).open()
    with context as stream:
        for line_number, line in enumerate(stream, 1):
            # Normalize each line, then select termination, comment skipping, or numeric parsing.
            match line.strip():
                case "":
                    break
                case comment if comment.startswith("#"):
                    continue
                case text:
                    try:
                        values.append(number(text))
                    except ValueError as error:
                        print(f"warning: line {line_number}: {error}; skipped", file=sys.stderr)
            # Stop excessive input before allocating a worker pool.
            if len(values) > 4096:
                raise ValueError("at most 4096 values are allowed")
    if not values:
        raise ValueError("no valid input values")
    return values


# Coordinate argument parsing, input, process work, output, and user-facing failures.
# Inputs: Command-line arguments and, in interactive mode, standard input.
# Outputs: An exit status; on success, a CSV file and a completion message.
# Used by: The __main__ guard when this file is launched as a program.
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", default="-", help="input file, or - for stdin")
    parser.add_argument("output", nargs="?", default="results.csv")
    parser.add_argument("workers", nargs="?", type=int, default=2, choices=range(1, 17))
    args = parser.parse_args()
    try:
        values = read_values(args.input)
        # Spawn works on Windows too and avoids inherited file handles.
        with ProcessPoolExecutor(max_workers=args.workers,
                                 mp_context=multiprocessing.get_context("spawn")) as pool:
            # Wait for all ordered results; a failed worker propagates through this call.
            rows = list(pool.map(observe, values, chunksize=1))
        # Create the requested output only after the complete calculation succeeds.
        with Path(args.output).open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("x", "j0", "worker_pid"))
            writer.writerows(rows)
        print(f"Wrote {len(rows)} observations to {args.output}")
        return 0
    # Turn expected input, filesystem, and worker failures into a concise diagnostic.
    except (OSError, ValueError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("error: interrupted", file=sys.stderr)
        return 130


# Prevent spawned workers from recursively starting another command-line session.
if __name__ == "__main__":
    raise SystemExit(main())
