#!/usr/bin/env perl

=pod

Bessel Observatory: read numeric observations, compute J0 in child processes, and save ordered CSV.
J0 is approximated by averaging cos(x*sin(theta)) at 16,384 midpoint angles.
Normal use: PROGRAM [INPUT|- [OUTPUT [WORKERS]]]. Invalid value lines are reported and skipped.

=cut

use v5.20;
use strict;
use warnings;
use POSIX qw(cos sin isfinite _exit);
use Scalar::Util qw(looks_like_number);


=pod

Validate one scalar token as a finite supported observation.
Inputs: The token passed as the first subroutine argument.
Outputs: A numeric scalar, or a die exception describing invalid input.
Used by: The top-level reading loop, inside eval so one bad line is recoverable.

=cut

sub number {
    my ($s) = @_;
    die "expected a finite x in [-1000,1000]\n"
        unless looks_like_number($s) && isfinite(0 + $s) && abs($s) <= 1000;
    return 0 + $s;
}


=pod

Compute a group in independent processes and return their results in order.
Inputs: The list of x values for one bounded batch.
Outputs: CSV row strings; pipe or worker failures die after cleanup.
Used by: The top-level splice loop, once per worker-sized group.

=cut

sub batch {
    my @children;
    my @rows;
    # Capture failures while launching or collecting so already-started children can still be reaped.
    my $ok = eval {
        for my $x (@_) {
            pipe(my $reader, my $writer) or die "pipe: $!\n";
            my $pid = fork();
            die "fork: $!\n" unless defined $pid;
            # Perform the numerical work only in the forked child and terminate it with _exit.
            if (!$pid) {
                close $reader;
                my $sum = 0;
                $sum += cos($x * sin(4 * atan2(1, 1) * ($_ + 0.5) / 16384)) for 0..16383;
                my $written = printf {$writer} "%.17g,%.17g,%d\n", $x, $sum / 16384, $$;
                my $closed = close $writer;
                _exit($written && $closed ? 0 : 1);
            }
            close $writer;
            push @children, [$pid, $reader];
        }
        # Drain and validate every child after the whole batch has been launched.
        for my $child (@children) {
            my ($pid, $reader) = @$child;
            my $row = do { local $/; <$reader> };
            waitpid($pid, 0) == $pid or die "waitpid: $!\n";
            die "worker $pid failed\n" if $? != 0 || !length($row // '');
            push @rows, $row;
        }
        1;
    };
    # Save the original exception before cleanup calls can disturb Perl error state.
    my $error = $@;
    for my $child (@children) { close $child->[1]; waitpid($child->[0], 0); }
    die $error unless $ok;
    return @rows;
}

if (@ARGV == 1 && $ARGV[0] eq '--help') {
    say 'Usage: perl bessel.pl [INPUT|- [OUTPUT [WORKERS 1..16]]]'; exit 0;
}
eval {
    die "too many arguments\n" if @ARGV > 3;
    # Apply defaults and keep CLI values local to this run.
    my ($source, $target, $jobs) = ($ARGV[0] // '-', $ARGV[1] // 'results.csv', $ARGV[2] // '2');
    die "workers must be 1..16\n" unless $jobs =~ /^\d+$/ && $jobs >= 1 && $jobs <= 16;
    my $input;
    if ($source eq '-') { $input = *STDIN; say STDERR 'Enter one x per line; blank line or EOF finishes:'; }
    else { open $input, '<', $source or die "open $source: $!\n"; }
    my @values;
    my $line = 0;
    # Strip surrounding whitespace, stop on a blank line, and skip comment lines.
    while (my $text = <$input>) {
        ++$line; $text =~ s/^\s+|\s+$//g;
        last unless length $text;
        next if $text =~ /^#/;
        # Treat malformed numeric input as a skipped line rather than a fatal program error.
        my $x = eval { number($text) };
        if ($@) { warn "warning: line $line: invalid number; skipped\n"; next; }
        push @values, $x;
        die "at most 4096 values\n" if @values > 4096;
    }
    close $input if $source ne '-';
    die "no valid input values\n" unless @values;
    my @rows;
    # Remove one bounded slice at a time while keeping output rows in the same sequence.
    push @rows, batch(splice @values, 0, $jobs) while @values;
    # Open the target only after all values have been computed.
    open my $output, '>', $target or die "open $target: $!\n";
    print {$output} "x,j0,worker_pid\n", @rows or die "write: $!\n";
    close $output or die "close: $!\n";
    say 'Wrote ' . scalar(@rows) . " observations to $target";
    1;
# Convert a fatal top-level exception into a concise diagnostic and failure status.
} or do { warn "error: $@"; exit 1; };
