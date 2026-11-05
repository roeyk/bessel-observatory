#!/usr/bin/env node
/*
  Bessel Observatory: read x values, compute the same midpoint integral in OS workers, and write CSV.
  The normal argument order is input file (or -), output file, then worker limit.
  User input is validated before workers start; malformed numeric lines are reported and skipped.
  Node.js 20+: async iteration, promises, and child_process.fork with IPC.
*/
import { fork } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

/*
  Parse a numeric token without accepting empty or non-finite values.
  Inputs: A string supplied by the input reader or worker CLI.
  Outputs: A bounded Number, or an Error.
  Used by: main before scheduling a value or computing a child result.
*/
function number(text) {
  const x = Number(text);
  if (!text.trim() || !Number.isFinite(x) || Math.abs(x) > 1000)
    throw new Error('expected a finite x in [-1000,1000]');
  return x;
}
/*
  Calculate one observation using checked byte offsets into a shared buffer.
  Inputs: One validated numeric x.
  Outputs: A complete CSV row with x, J0 and the current OS PID.
  Used by: main when the forked Node process enters --worker mode.
*/
function observe(x) {
  /*
    ArrayBuffer and DataView share a referenced allocation. Byte offsets are
    explicit but checked: JavaScript exposes no raw memory pointers.
  */
  const width = Float64Array.BYTES_PER_ELEMENT;
  const samples = new DataView(new ArrayBuffer(16384 * width));
  for (let k = 0; k < 16384; k++)
    samples.setFloat64(k * width, Math.cos(x * Math.sin(Math.PI * (k + 0.5) / 16384)), true);
  let sum = 0;
  for (let k = 0; k < 16384; k++) sum += samples.getFloat64(k * width, true);
  return `${x},${sum / 16384},${process.pid}\n`;
}
/*
  Start a Node child and represent its eventual result as a Promise.
  Inputs: A value x and the parent-owned set of active child handles.
  Outputs: A Promise for one CSV row; rejection reports launch or child failure.
  Used by: main through Promise.all to coordinate each bounded process batch.
*/
function worker(x, active) {
  return new Promise((resolve, reject) => {
    const child = fork(fileURLToPath(import.meta.url), ['--worker', String(x)],
      { stdio: ['inherit', 'inherit', 'inherit', 'ipc'] });
    // Retain the child so an enclosing failure can still terminate it.
    active.add(child);
    let row = '';
    // Receive the child result through Node IPC rather than parsing interleaved console output.
    child.on('message', message => { if (typeof message === 'string') row = message; });
    child.on('error', reject);
    // Accept a result only once the child has exited successfully.
    child.on('close', code => {
      active.delete(child);
      if (code === 0 && row.length) resolve(row);
      else reject(new Error(`worker failed (${code})`));
    });
  });
}
/*
  Coordinate asynchronous input, process dispatch, and result-file output.
  Inputs: The program arguments and, optionally, stdin.
  Outputs: A resolved Promise after writing results, or a rejected Promise on failure.
  Used by: The final invocation, whose catch handler sets the process exit status.
*/
async function main(args) {
  if (args.length === 1 && args[0] === '--help') {
    console.log('Usage: node bessel.mjs [INPUT|- [OUTPUT [WORKERS 1..16]]]'); return;
  }
  if (args.length === 2 && args[0] === '--worker') {
    const row = observe(number(args[1]));
    // Use IPC when launched by the parent; retain stdout output for direct worker invocation.
    if (process.send) process.send(row, () => process.disconnect());
    else process.stdout.write(row);
    return;
  }
  if (args.length > 3) throw new Error('too many arguments');
  const [source = '-', target = 'results.csv', jobsText = '2'] = args;
  const jobs = Number(jobsText);
  if (!/^\d+$/.test(jobsText) || !Number.isInteger(jobs) || jobs < 1 || jobs > 16)
    throw new Error('workers must be 1..16');
  if (source === '-') console.error('Enter one x per line; blank line or EOF finishes:');
  const input = source === '-' ? process.stdin : createReadStream(source, { encoding: 'utf8' });
  const lines = createInterface({ input, crlfDelay: Infinity });
  const values = [];
  try {
    // Consume lines as they arrive instead of requiring the entire input file in memory.
    for await (const line of lines) {
      const text = line.trim();
      if (!text) break;
      if (text.startsWith('#')) continue;
      try { values.push(number(text)); }
      catch (error) { console.error(`warning: ${error.message}; skipped`); }
      if (values.length > 4096) throw new Error('at most 4096 values');
    }
  // Release the readline interface and close owned file streams even after parsing failures.
  } finally { lines.close(); if (source !== '-') input.destroy(); }
  if (!values.length) throw new Error('no valid input values');
  const rows = []; const active = new Set();
  try {
    for (let i = 0; i < values.length; i += jobs)
      // Launch this group together and preserve input order in the returned Promise results.
      rows.push(...await Promise.all(values.slice(i, i + jobs).map(x => worker(x, active))));
  } finally { for (const child of active) child.kill(); }
  // Write the final ordered CSV only after every batch has succeeded.
  await writeFile(target, 'x,j0,worker_pid\n' + rows.join(''));
  console.log(`Wrote ${rows.length} observations to ${target}`);
}
// Strip the Node executable/script arguments and report rejected work without a stack dump.
main(process.argv.slice(2)).catch(error => { console.error(`error: ${error.message}`); process.exitCode = 1; });
