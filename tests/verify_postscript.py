#!/usr/bin/env python3
# Exercise the PostScript arithmetic and process boundary beyond the shared suite.
import argparse
import csv
from decimal import Decimal, localcontext
import json
from pathlib import Path
import random
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
Q = 2**52


# Run a PostScript arithmetic probe with the application entry point disabled.
# Inputs: executable and code. Output: stdout lines. Used by arithmetic checks;
# the production edition does not depend on Python or this test harness.
def library(gs, code):
    run = subprocess.run([gs, '-q', '-dNODISPLAY', '-dBATCH', '-dBesselLibrary',
                          'bessel.ps', '-'], cwd=ROOT, input=code, capture_output=True,
                         text=True, timeout=90)
    assert run.returncode == 0, (run.stdout[-2000:], run.stderr)
    return run.stdout.splitlines()


# Compare products, decimal conversion and quadrature to independent references.
# Input: Ghostscript path. Output: maximum observed J0 error; assertions on failure.
# Called by main before OS and failure probes. Python integers are exact and the
# stored Bessel values were independently generated with mpmath at 80 digits.
def arithmetic(gs):
    rng = random.Random(2601106)
    pairs = [(a, b) for a in (0, 1, -1, Q, -Q, 1000*Q, -1000*Q)
             for b in (0, 1, -1, Q-1, Q, -Q)]
    pairs += [(rng.randrange(-1000*Q, 1000*Q), rng.randrange(-Q, Q))
              for _ in range(256)]
    products = library(gs, '\n'.join(f'{a} {b} fmul ==' for a, b in pairs))
    for (a, b), text in zip(pairs, products, strict=True):
        expected = abs(a*b) // Q * (-1 if (a < 0) != (b < 0) else 1)
        assert int(text) == expected, (a, b, text, expected)

    decimals = ['0', '-0', '+.5E2', '000001.25000', '1.', '1000', '-1000',
                '999.999999999999999', '1e-4000', '0e999999', '-3.14e-10']
    decimals += [format(rng.uniform(-1000, 1000), '.18f') for _ in range(128)]
    parsed = library(gs, '\n'.join(f'({s}) number decimal =' for s in decimals))
    with localcontext() as context:
        context.prec = 80
        for source, value in zip(decimals, parsed, strict=True):
            assert abs(Decimal(source)-Decimal(value)) < Decimal('4e-16'), (source, value)

    refs = json.loads((ROOT/'tests/postscript-reference.json').read_text())
    answers = library(gs, '\n'.join(f'({r["x"]}) number observe decimal ='
                                   for r in refs['values']))
    errors = [abs(Decimal(text)-Decimal(r['j0']))
              for text, r in zip(answers, refs['values'], strict=True)]
    assert max(errors) < Decimal(str(refs['absolute_tolerance'])), max(errors)
    print(f'Arithmetic: {len(pairs)} exact products, {len(decimals)} decimal cases, '
          f'{len(errors)} independent J0 references; max error {max(errors):.3E}', flush=True)
    return max(errors)


# Execute a CLI case and require the specified exit behavior.
# Inputs: interpreter, args, stdin, optional source override. Output: process result.
# Used by the malformed-input, file, and injected-worker-failure checks.
def invoke(gs, args, stdin='', success=True, source=None, cwd=ROOT):
    command = [gs, '-q', '-dNODISPLAY', '-dBATCH', '-dNOSAFER']
    if source:
        command.append(f'-sBesselSource={source}')
    command += ['--', str(ROOT/'bessel.ps'), *map(str, args)]
    run = subprocess.run(command, cwd=cwd, input=stdin, capture_output=True,
                         text=True, timeout=90)
    assert (run.returncode == 0) == success, (args, run.returncode, run.stdout, run.stderr)
    if not success:
        assert 'error:' in run.stderr, run.stderr
    return run


# Verify data is never executed and failures preserve a pre-existing output.
# Inputs: interpreter and temporary directory. Output: assertions and diagnostic.
# Called by main; fake workers test the IPC boundary, not a substitute kernel.
def failures(gs, folder):
    output = folder/'result.csv'
    bad = ['NaN', 'Infinity', '1e309', '1000.000000000000000000001',
           '-1000.000000000000000000001', '1 2', '0x10', '1e', '1e+',
           '.', '+', '1.2.3', '1e2junk', '1e1.5', 'quit', '{quit}', '16#FF']
    run = invoke(gs, ['-', output, '2'], '\n'.join(bad + ['0', '1', '', '5']))
    assert run.stderr.count('warning:') == len(bad), run.stderr
    rows = list(csv.DictReader(output.open()))
    assert [float(row['x']) for row in rows] == [0, 1], rows
    for stdin in ('1'*4097+'\n', 'bad\n\n'):
        output.write_text('preserve me\n')
        invoke(gs, ['-', output], stdin, success=False)
        assert output.read_text() == 'preserve me\n'
    invoke(gs, [folder, output], success=False)
    if Path('/dev/full').exists():
        invoke(gs, ['-', '/dev/full'], '0\n', success=False)

    # A source path containing shell metacharacters must remain one argument.
    source = folder/"worker ' $() ; quoted.ps"
    source.write_bytes((ROOT/'bessel.ps').read_bytes())
    weird = folder/"results ' $() ; quoted.csv"
    invoke(gs, ['-', weird, 1], '1\n', source=source, cwd=folder)
    assert len(list(csv.DictReader(weird.open()))) == 1
    # A user filename beginning %pipe% is an ordinary OS path, not a command.
    literal = '%pipe%must-be-a-file.csv'
    invoke(gs, ['-', literal, 1], '0\n', source=source, cwd=folder)
    assert (folder/literal).is_file()

    for body in ('null 7 .quit\n', '(0\\n) print flush quit\n',
                 '(0\\n1\\nWRONG\\n) print flush quit\n',
                 '(0\\n1\\nDONE\\nextra\\n) print flush quit\n',
                 '(0\\n1\\nDONE\\n) print flush null 7 .quit\n'):
        source.write_text(body)
        output.write_text('preserve me\n')
        invoke(gs, ['-', output, 4], '1\n2\n3\n4\n', success=False, source=source)
        assert output.read_text() == 'preserve me\n'
    print('Failures: malformed decimals, domain edges, long lines, file errors, '
          'quoted paths and incomplete/failed workers passed', flush=True)


# Observe genuine child interpreters and compare their PIDs with the CSV.
# Inputs: interpreter, temporary directory, worker limit. Output: assertions.
# Called by main for limits 1 and 16. Reading cmdline excludes a transient shell;
# the scan verifies observed concurrency, not an exhaustive OS scheduling trace.
def processes(gs, folder, workers):
    output = folder/f'workers-{workers}.csv'
    command = [gs, '-q', '-dNODISPLAY', '-dBATCH', '-dNOSAFER', '--',
               'bessel.ps', '-', str(output), str(workers)]
    process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    process.stdin.write('1000\n' * 32)
    process.stdin.close()
    seen = set()
    peak = 0
    deadline = time.monotonic() + 90
    while process.poll() is None:
        if time.monotonic() > deadline:
            process.kill()
            raise AssertionError('worker observation timed out')
        children = Path(f'/proc/{process.pid}/task/{process.pid}/children')
        try:
            pids = children.read_text().split()
        except FileNotFoundError:
            pids = []
        active = set()
        for pid in pids:
            try:
                if b'--worker' in Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0'):
                    active.add(int(pid))
            except FileNotFoundError:
                pass
        seen |= active
        peak = max(peak, len(active))
        assert len(active) <= workers, (workers, active)
        time.sleep(.005)
    stdout, stderr = process.stdout.read(), process.stderr.read()
    assert process.returncode == 0, (stdout, stderr)
    rows = list(csv.DictReader(output.open()))
    reported = {int(row['worker_pid']) for row in rows}
    assert len(rows) == len(reported) == 32
    assert reported <= seen, (reported-seen)
    assert peak == workers, (workers, peak)
    print(f'Processes: limit {workers}, observed peak {peak}, all 32 CSV PIDs '
          'matched live numeric child interpreters', flush=True)


# Select an installed interpreter and run all focused checks.
# Inputs: CLI --ghostscript path and optional --arithmetic-only.
# Outputs: progress and nonzero exit on any assertion. Entry point for developers.
def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ghostscript', default='gs')
    parser.add_argument('--arithmetic-only', action='store_true')
    args = parser.parse_args()
    gs = str(Path(args.ghostscript).resolve()) if '/' in args.ghostscript else args.ghostscript
    arithmetic(gs)
    if not args.arithmetic_only:
        with tempfile.TemporaryDirectory(prefix='bessel-ps-') as temporary:
            folder = Path(temporary)
            failures(gs, folder)
            for workers in (1, 16):
                processes(gs, folder, workers)
    print('PostScript focused checks passed.')


if __name__ == '__main__':
    main()
