/*
  Bessel Observatory: read numeric observations, compute J0 in child processes, and save ordered CSV.
  J0 is approximated by averaging cos(x*sin(theta)) at 16,384 midpoint angles.
  Normal use: PROGRAM [INPUT|- [OUTPUT [WORKERS]]]. Invalid value lines are reported and skipped.
  C++20 + POSIX. RAII owns descriptors and child lifetimes; exceptions carry errors.
*/
#include <algorithm>
#include <cerrno>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <numbers>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/wait.h>
#include <unistd.h>

struct Observation { double x, j0; long pid; };
/*
  Parse a complete token and enforce the supported input range.
  Inputs: A string containing one number.
  Outputs: A finite double, or a standard conversion/domain exception.
  Used by: main when it validates input lines.
*/
double number(const std::string& s) {
    std::size_t end; double x = std::stod(s, &end);
    if (s.find_first_not_of(" \t\r\n", end) != std::string::npos || !std::isfinite(x) || std::abs(x) > 1000)
        throw std::invalid_argument("expected a finite x in [-1000,1000]");
    return x;
}
/*
  Calculate the quadrature result in the current process.
  Inputs: A validated x value.
  Outputs: An Observation containing the value, result and OS PID.
  Used by: The Worker constructor child branch after fork.
*/
Observation observe(double x) {
    double sum = 0;
    for (int k = 0; k < 16384; ++k)
        sum += std::cos(x * std::sin(std::numbers::pi * (k + 0.5) / 16384));
    return {x, sum / 16384, static_cast<long>(getpid())};
}
class Worker {
    pid_t pid_ = -1;
    int read_ = -1;
public:
    /*
      Acquire a pipe and start one child whose lifetime belongs to this object.
      Inputs: The x value assigned to this child.
      Outputs: A live Worker owning a PID and read descriptor; creation failures throw.
      Used by: main through make_unique while building a concurrent batch.
    */
    explicit Worker(double x) {
        int fds[2];
        if (pipe(fds)) throw std::runtime_error("pipe failed");
        pid_ = fork();
        if (pid_ == 0) {
            close(fds[0]); auto row = observe(x);
            auto sent = write(fds[1], &row, sizeof row);
            close(fds[1]); _exit(sent == sizeof row ? 0 : 1);
        }
        close(fds[1]);
        if (pid_ < 0) { close(fds[0]); throw std::runtime_error("fork failed"); }
        read_ = fds[0];
    }
    // Disallow copies so two objects cannot accidentally own the same PID and descriptor.
    Worker(const Worker&) = delete;
    Worker& operator=(const Worker&) = delete;
    /*
      Release the pipe and reap a child even during exception unwinding.
      Inputs: The resources still owned by this Worker.
      Outputs: No return value; owned OS resources are released.
      Used by: unique_ptr destruction when a batch finishes or an exception exits its scope.
    */
    ~Worker() {
        if (read_ >= 0) close(read_);
        if (pid_ > 0) { int status; while (waitpid(pid_, &status, 0) < 0 && errno == EINTR) {} }
    }
    /*
      Read the complete child payload and verify that the child succeeded.
      Inputs: This Worker and its owned reading endpoint.
      Outputs: One Observation, or an exception for pipe or child failure.
      Used by: main after all workers in a batch have been started.
    */
    Observation collect() {
        Observation row{};
        // View the result storage as bytes so partial reads can fill it without losing their position.
        char* p = reinterpret_cast<char*>(&row); std::size_t remaining = sizeof row;
        while (remaining) {
            auto n = read(read_, p, remaining);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) throw std::runtime_error("worker pipe closed early");
            p += n; remaining -= static_cast<std::size_t>(n);
        }
        int status; pid_t waited;
        do { waited = waitpid(pid_, &status, 0); } while (waited < 0 && errno == EINTR);
        pid_ = -1;
        if (waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status)) throw std::runtime_error("worker failed");
        return row;
    }
};
/*
  Coordinate the experiment using exceptions for errors and RAII for cleanup.
  Inputs: Program arguments and a file or stdin.
  Outputs: An ordered CSV on success; a diagnostic and nonzero exit on failure.
  Used by: The executable startup code.
*/
int main(int argc, char** argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--help") {
            std::cout << "Usage: bessel-cpp [INPUT|- [OUTPUT [WORKERS 1..16]]]\n"; return 0;
        }
        if (argc > 4) throw std::invalid_argument("too many arguments");
        std::string source = argc > 1 ? argv[1] : "-", target = argc > 2 ? argv[2] : "results.csv";
        std::size_t end = 0; int jobs = argc > 3 ? std::stoi(argv[3], &end) : 2;
        if (jobs < 1 || jobs > 16 || (argc > 3 && end != std::string(argv[3]).size()))
            throw std::invalid_argument("workers must be 1..16");
        std::ifstream file;
        if (source != "-") { file.open(source); if (!file) throw std::runtime_error("cannot open input"); }
        else std::cerr << "Enter one x per line; blank line or EOF finishes:\n";
        // Borrow either the file stream or stdin through the same reading interface.
        std::istream& input = source == "-" ? std::cin : file;
        std::vector<double> values;
        // Normalize and validate each line; a bad numeric line does not abort the whole input.
        for (std::string line; std::getline(input, line);) {
            auto begin = line.find_first_not_of(" \t\r\n");
            if (begin == std::string::npos) break;
            if (line[begin] == '#') continue;
            try { values.push_back(number(line)); }
            catch (const std::exception& e) { std::cerr << "warning: " << e.what() << "; skipped\n"; }
            if (values.size() > 4096) throw std::runtime_error("at most 4096 values");
        }
        if (input.bad()) throw std::runtime_error("input read failed");
        if (values.empty()) throw std::runtime_error("no valid input values");
        std::vector<Observation> rows;
        for (std::size_t i = 0; i < values.size(); i += jobs) {
            // Keep all child owners alive together so they calculate concurrently.
            std::vector<std::unique_ptr<Worker>> workers;
            for (auto j = i; j < std::min(values.size(), i + jobs); ++j)
                workers.push_back(std::make_unique<Worker>(values[j]));
            for (auto& worker : workers) rows.push_back(worker->collect());
        }
        // Make stream failures throw, allowing the outer handler to report write errors too.
        std::ofstream output; output.exceptions(std::ios::failbit | std::ios::badbit);
        output.open(target); output << "x,j0,worker_pid\n" << std::setprecision(17);
        for (const auto& [x, j0, pid] : rows) output << x << ',' << j0 << ',' << pid << '\n';
        output.close(); std::cout << "Wrote " << rows.size() << " observations to " << target << '\n';
    } catch (const std::exception& e) { std::cerr << "error: " << e.what() << '\n'; return 1; }
}
