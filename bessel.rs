/*
  Bessel Observatory: read numeric observations, compute J0 in child processes, and save ordered CSV.
  J0 is approximated by averaging cos(x*sin(theta)) at 16,384 midpoint angles.
  Normal use: PROGRAM [INPUT|- [OUTPUT [WORKERS]]]. Invalid value lines are reported and skipped.
  Rust 2021; no crates. Result, iterators, ownership, and real child processes.
*/
use std::{env, error::Error, fs::File, io::{self, BufRead, BufReader, Write},
          process::{self, Child, Command, Stdio}};
type Result<T> = std::result::Result<T, Box<dyn Error>>;

/*
  Convert one token into a bounded observation value.
  Inputs: A borrowed string slice.
  Outputs: Result containing a finite f64, or a descriptive error.
  Used by: run for file input and the internal worker command.
*/
fn number(s: &str) -> Result<f64> {
    let x: f64 = s.trim().parse()?;
    if !x.is_finite() || x.abs() > 1000.0 { return Err("expected finite x in [-1000,1000]".into()); }
    Ok(x)
}
/*
  Generate midpoint samples and reduce their values to J0.
  Inputs: A validated f64 x.
  Outputs: The approximate J0 result.
  Used by: run when it is executing the internal worker mode.
*/
fn observe(x: f64) -> f64 {
    let samples: Vec<f64> = (0..16384)
        .map(|k| (x * (std::f64::consts::PI * (k as f64 + 0.5) / 16384.0).sin()).cos()).collect();
    sum_buffer(&samples) / 16384.0
}
/*
  Demonstrate a borrowed raw-pointer walk without transferring ownership.
  Inputs: An immutable slice of initialized f64 samples.
  Outputs: Their sum; memory ownership remains with the caller.
  Used by: observe to reduce the numerical samples.
*/
fn sum_buffer(samples: &[f64]) -> f64 {
    let base = samples.as_ptr();
    (0..samples.len()).map(|i| {
        /*
          SAFETY: i is in bounds; the borrowed slice owns live, aligned f64s
          for this entire call. add advances in ELEMENTS, not bytes.
          This isolated unsafe block is an educational pointer example;
          ordinary Rust would use samples.iter().sum().
        */
        unsafe { *base.add(i) }
    }).sum()
}
// Drop also reaps children if spawning or collecting a later child fails.
struct Worker(Option<Child>);
impl Drop for Worker {
    /*
      Ensure abandoning a Worker does not leave a running or unreaped child.
      Inputs: The optional child still owned by this wrapper.
      Outputs: No value; a remaining child is killed and waited for.
      Used by: Rust drop glue on normal scope exit and early Result propagation.
    */
    fn drop(&mut self) {
        if let Some(child) = self.0.as_mut() { let _ = child.kill(); let _ = child.wait(); }
    }
}
/*
  Select CLI or worker behavior and perform the experiment with fallible operations.
  Inputs: Command-line arguments and, in normal mode, input data.
  Outputs: Ok on success or an error describing the failed operation.
  Used by: main, which turns errors into a diagnostic and process exit status.
*/
fn run() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    // Separate help and child computation from the ordinary interactive/file workflow.
    match args.as_slice() {
        [flag] if flag == "--help" => {
            println!("Usage: bessel-rust [INPUT|- [OUTPUT [WORKERS 1..16]]]"); return Ok(());
        }
        [flag, x] if flag == "--worker" => {
            let x = number(x)?;
            println!("{x:.17},{:.17},{}", observe(x), process::id()); return Ok(());
        }
        _ => {}
    }
    if args.len() > 3 { return Err("too many arguments".into()); }
    let source = args.first().map_or("-", String::as_str);
    let target = args.get(1).map_or("results.csv", String::as_str);
    let jobs: usize = args.get(2).map_or("2", String::as_str).parse()?;
    if !(1..=16).contains(&jobs) { return Err("workers must be 1..16".into()); }
    // Expose a file or stdin through a shared buffered-reading interface.
    let input: Box<dyn BufRead> = if source == "-" {
        eprintln!("Enter one x per line; blank line or EOF finishes:"); Box::new(io::stdin().lock())
    } else { Box::new(BufReader::new(File::open(source)?)) };
    let mut values = Vec::new();
    // Preserve line order and include line numbers in recoverable input diagnostics.
    for (index, line) in input.lines().enumerate() {
        let line = line?; let text = line.trim();
        match text {
            "" => break,
            s if s.starts_with('#') => continue,
            s => match number(s) {
                Ok(x) => values.push(x),
                Err(e) => eprintln!("warning: line {}: {e}; skipped", index + 1),
            }
        }
        if values.len() > 4096 { return Err("at most 4096 values".into()); }
    }
    if values.is_empty() { return Err("no valid input values".into()); }
    let executable = env::current_exe()?;
    let mut rows = String::from("x,j0,worker_pid\n");
    // Bound concurrent processes without requiring a nonstandard process-pool crate.
    for batch in values.chunks(jobs) {
        let mut children = Vec::new();
        for x in batch {
            children.push(Worker(Some(Command::new(&executable).arg("--worker").arg(x.to_string())
                .stdin(Stdio::null()).stdout(Stdio::piped()).spawn()?)));
        }
        // Drain each child output and validate its status before appending its CSV row.
        for worker in &mut children {
            let output = worker.0.take().ok_or("missing child")?.wait_with_output()?;
            if !output.status.success() || output.stdout.is_empty() { return Err("worker failed".into()); }
            rows.push_str(std::str::from_utf8(&output.stdout)?);
        }
    }
    // Write the accumulated CSV after all numerical work is complete.
    let mut output = File::create(target)?;
    output.write_all(rows.as_bytes())?; output.flush()?;
    println!("Wrote {} observations to {target}", values.len()); Ok(())
}
/*
  Provide the executable entry point and final error boundary.
  Inputs: The process environment, consumed by run.
  Outputs: Success output or a nonzero process exit after printing the error.
  Used by: Rust runtime startup.
*/
fn main() {
    if let Err(e) = run() { eprintln!("error: {e}"); process::exit(1); }
}
