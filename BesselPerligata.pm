package BesselPerligata;
use strict;
use warnings;
use Exporter 'import';
use POSIX qw(isfinite _exit);
use File::Temp qw(tempdir);
use Errno qw(EINTR);
our @EXPORT = qw(terg prob reg accip loc gign collig cognosc disced teg);

=pod

Compatibility services for bessel-perligata.pl, never a numerical kernel.
Perligata 0.605 lacks implemented regex syntax and rejects the straightforward
no-argument fork form. Its perlege reader converts Roman numerals in input;
accip deliberately reads unchanged bytes and distinguishes EOF from errors.
The remaining services manage POSIX process identity/status, temporary storage,
and exception cleanup. Opening, writing and closing files stay in Latin.
Exported Latin verb stems acquire Perligata's regular conjugation at call sites.

=cut

my (%live, %rows);
my $owner = $$;
my $directory;

=pod

tergere (wipe): trim surrounding whitespace through a scalar reference.
Inputs: reference to the caller's line. Outputs: modified referent.
Used by: agere before classifying lines; the caller retains the string's owner.

=cut

sub terg { ${$_[0]} =~ s/^\s+|\s+$//g; }

=pod

probare (test): accept only complete finite decimal observations in range.
Inputs: string. Outputs: Boolean acceptance, without altering the string.
Used by: agere to warn and skip invalid lines before scheduling workers.

=cut

sub prob {
    my ($text) = @_;
    return $text =~ /\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
        && isfinite(0 + $text) && abs($text) <= 1000;
}

=pod

regere (govern): validate the worker limit before any process is started.
Inputs: argument string. Outputs: integer 1..16, or exception.
Used by: agere to enforce bounded batches, rejecting fractional counts.

=cut

sub reg {
    my ($text) = @_;
    $text =~ /\A[0-9]+\z/ && $text >= 1 && $text <= 16
        or die "workers must be 1..16\n";
    return 0 + $text;
}

=pod

accipere (receive): read one unchanged line with checked EOF handling.
Inputs: readable handle reference. Outputs: line, undef at EOF, or exception.
Used by: agere for observations and completed CSV rows. Clearing errno first
prevents an earlier system error from being mistaken for this read's failure.

=cut

sub accip {
    my ($handle) = @_;
    $! = 0;
    my $line = <$handle>;
    die "read: $!\n" if !defined($line) && $!;
    return $line;
}

=pod

locare (place): name a worker row in storage owned by this invocation.
Inputs: observation ordinal. Outputs: private pathname, or exception.
Used by: agere before forking and when gathering rows. Creating the directory
in the parent makes cleanup ownership independent of child completion order.

=cut

sub loc {
    my ($ordinal) = @_;
    $directory //= tempdir(CLEANUP => 0);
    return $rows{$ordinal} //= "$directory/$ordinal.csv";
}

=pod

gignere (beget): fork and immediately register the child in its parent.
Inputs: none. Outputs: child PID in parent, zero in child, or exception.
Used by: agere to branch into a worker; registration covers later failures.

=cut

sub gign {
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    $live{$pid} = 1 if $pid;
    return $pid;
}

=pod

colligere (gather): reap a particular child and check its exit status.
Inputs: child PID. Outputs: removed live-child record, or exception.
Used by: agere at each batch boundary. Interrupted waits retry; a failed worker
is removed after reaping so cleanup never signals an already-reaped PID.

=cut

sub collig {
    my ($pid) = @_;
    my $got;
    do { $got = waitpid($pid, 0) } while $got < 0 && $! == EINTR;
    my $status = $?;
    die "wait for worker $pid: $!\n" if $got != $pid;
    delete $live{$pid};
    die "worker $pid failed (status $status)\n" if $status;
}

=pod

cognoscere (recognize): identify this actual operating-system process.
Inputs: none. Outputs: numeric PID. Used by: agere's child to label its CSV row.

=cut

sub cognosc { return $$; }

=pod

discedere (depart): exit a successful child without inherited finalizers.
Inputs: none. Outputs: process exits with status zero; never returns.
Used by: agere's child only after native print and close have succeeded.

=cut

sub disced { _exit(0); }

=pod

tegere (protect): run the Latin entry point inside an exception boundary.
Inputs: code reference. Outputs: exit 0 on success or diagnostic and exit 1.
Used by: the final Latin statement, tege agtorem, to protect the whole run.
Only the original parent terminates outstanding workers and removes row files;
failed children report their error and exit without touching sibling resources.

=cut

sub teg {
    my ($entry) = @_;
    my $ok = eval { $entry->(); 1 };
    my $error = $@;
    if ($$ == $owner) {
        # Stop all outstanding workers before waiting or removing their files.
        kill 'TERM', keys %live if %live;
        for my $pid (keys %live) {
            my $got;
            do { $got = waitpid($pid, 0) } while $got < 0 && $! == EINTR;
        }
        if (defined $directory) {
            unlink values %rows;
            rmdir $directory;
        }
    }
    if (!$ok) {
        print STDERR "bessel: $error";
        _exit(1) if $$ != $owner;
        exit 1;
    }
    exit 0;
}

1;  # Tell Perl that loading the compatibility module succeeded.
