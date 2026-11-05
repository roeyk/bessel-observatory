/*
  Bessel Observatory: read numeric observations, compute J0 in child processes, and save ordered CSV.
  J0 is approximated by averaging cos(x*sin(theta)) at 16,384 midpoint angles.
  Normal use: PROGRAM [INPUT|- [OUTPUT [WORKERS]]]. Invalid value lines are reported and skipped.
*/
/* C17 + POSIX: explicit ownership, checked return codes, fork and pipe. */
#define _POSIX_C_SOURCE 200809L
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Bound input storage and choose the same quadrature resolution as the other editions.
enum { LIMIT = 4096, SAMPLES = 16384 };
typedef struct { double x, j0; long pid; } Observation;

/*
  Convert a complete input token and enforce the numerical domain.
  Inputs: Text s and a caller-owned output location x.
  Outputs: 1 and a stored double on success; 0 for invalid or out-of-domain input.
  Used by: main while reading each non-comment input line.
*/
static int parse(const char *s, double *x) {
    char *end;
    errno = 0;
    *x = strtod(s, &end);
    // Reject tokens that did not convert or overflowed the conversion range.
    if (end == s || errno == ERANGE) return 0;
    while (isspace((unsigned char)*end)) ++end;
    return !*end && isfinite(*x) && fabs(*x) <= 1000;
}

/*
  Approximate J0 for one value and identify the process that computed it.
  Inputs: One validated double x.
  Outputs: An Observation containing x, J0 and the current OS PID.
  Used by: The child branch in batch, after fork creates independent execution.
*/
static Observation observe(double x) {
    double sum = 0, pi = acos(-1);
    // Sample the integral at interval midpoints; dividing by SAMPLES supplies its normalization.
    for (int k = 0; k < SAMPLES; ++k)
        sum += cos(x * sin(pi * (k + 0.5) / SAMPLES));
    return (Observation){x, sum / SAMPLES, (long)getpid()};
}

/*
  Move an entire fixed-size payload across a pipe, including short transfers.
  Inputs: A descriptor, borrowed storage, its byte count, and a read/write direction.
  Outputs: 1 after all bytes move; 0 if the pipe closes or an unrecoverable I/O error occurs.
  Used by: Both parent and child in batch to exchange an Observation.
*/
static int transfer(int fd, void *data, size_t n, int writing) {
    /* Borrowed storage. p advances in bytes, always within the caller's n
       bytes; the owner remains alive until the transfer completes. */
    char *p = data;
    while (n) {
        ssize_t r = writing ? write(fd, p, n) : read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return 0;
        p += r; n -= (size_t)r;
    }
    return 1;
}

/*
  Start a bounded group of children and collect their results in input order.
  Inputs: An input slice xs, matching output storage rows, and group size n <= 16.
  Outputs: A success flag and populated rows; all started children are waited for.
  Used by: main once per group of requested observations.
*/
static int batch(const double *xs, Observation *rows, int n) {
    pid_t pids[16]; int readers[16], started = 0, ok = 1;
    for (int i = 0; i < n; ++i) {
        int fds[2];
        if (pipe(fds) < 0) { ok = 0; break; }
        pid_t pid = fork();
        // Compute only in the child and send its result before exiting without flushing inherited stdio.
        if (pid == 0) {
            close(fds[0]);
            for (int j = 0; j < started; ++j) close(readers[j]);
            Observation row = observe(xs[i]);
            int sent = transfer(fds[1], &row, sizeof row, 1);
            close(fds[1]); _exit(sent ? 0 : 1);
        }
        close(fds[1]);
        if (pid < 0) { close(fds[0]); ok = 0; break; }
        // Remember each child and its reading endpoint so the parent can clean up every started job.
        pids[started] = pid; readers[started++] = fds[0];
    }
    for (int i = 0; i < started; ++i) {
        int status = 0; pid_t waited;
        if (!transfer(readers[i], &rows[i], sizeof rows[i], 0)) ok = 0;
        close(readers[i]);
        // Retry interrupted waits and inspect the child exit status before accepting its result.
        do { waited = waitpid(pids[i], &status, 0); } while (waited < 0 && errno == EINTR);
        if (waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status)) ok = 0;
    }
    return ok;
}

/*
  Run the complete command-line experiment and report failures through exit status.
  Inputs: argc/argv plus an input file or standard input.
  Outputs: A CSV file and status 0, or a diagnostic and nonzero status.
  Used by: The operating system when the compiled executable is started.
*/
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--help")) {
        puts("Usage: bessel-c [INPUT|- [OUTPUT [WORKERS 1..16]]]"); return 0;
    }
    const char *source = argc > 1 ? argv[1] : "-";
    const char *target = argc > 2 ? argv[2] : "results.csv";
    char *end = NULL;
    long jobs = argc > 3 ? strtol(argv[3], &end, 10) : 2;
    if (argc > 4 || jobs < 1 || jobs > 16 || (argc > 3 && (end == argv[3] || *end))) {
        fputs("error: usage INPUT OUTPUT WORKERS; workers must be 1..16\n", stderr); return 1;
    }
    FILE *input = !strcmp(source, "-") ? stdin : fopen(source, "r");
    if (!input) { perror("error: input"); return 1; }
    if (input == stdin) fputs("Enter one x per line; blank line or EOF finishes:\n", stderr);
    double xs[LIMIT]; Observation rows[LIMIT];
    size_t count = 0, cap = 0, line_no = 0; char *line = NULL; int ok = 1;
    // Read complete lines, preserving their order and tracking a useful diagnostic line number.
    while (getline(&line, &cap, input) >= 0) {
        ++line_no; char *s = line;
        while (isspace((unsigned char)*s)) ++s;
        if (!*s) break;
        if (*s == '#') continue;
        double x;
        // Discard only this invalid observation; keep reading later values.
        if (!parse(s, &x)) { fprintf(stderr, "warning: line %zu: invalid number; skipped\n", line_no); continue; }
        if (count == LIMIT) { fputs("error: at most 4096 values\n", stderr); ok = 0; break; }
        xs[count++] = x;
    }
    if (ferror(input)) { perror("error: read"); ok = 0; }
    free(line); if (input != stdin) fclose(input);
    if (!ok) return 1;
    if (!count) { fputs("error: no valid input values\n", stderr); return 1; }
    // Limit simultaneous child processes by finishing one batch before starting the next.
    for (size_t i = 0; i < count; i += (size_t)jobs) {
        int n = (int)(count - i < (size_t)jobs ? count - i : (size_t)jobs);
        if (!batch(xs + i, rows + i, n)) { fputs("error: worker failed\n", stderr); return 1; }
    }
    // Open the result file after all worker batches have completed successfully.
    FILE *output = fopen(target, "w");
    if (!output) { perror("error: output"); return 1; }
    ok = fprintf(output, "x,j0,worker_pid\n") >= 0;
    for (size_t i = 0; i < count; ++i)
        if (fprintf(output, "%.17g,%.17g,%ld\n", rows[i].x, rows[i].j0, rows[i].pid) < 0) ok = 0;
    if (fclose(output) != 0) ok = 0;
    if (!ok) { perror("error: write"); return 1; }
    printf("Wrote %zu observations to %s\n", count, target); return 0;
}
