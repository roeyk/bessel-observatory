#!/usr/bin/env perl

=pod

Bessel Observatory in Lingua::Romana::Perligata 0.605 on POSIX Perl.
The Latin program below owns the mathematics, input loop, bounded fork batches,
and ordered output. This small Perl prelude bridges lexical filehandles,
regular expressions (unimplemented in the Latin grammar), and checked OS calls.
No numerical work is delegated to the prelude.

=cut

use POSIX qw(isfinite _exit);
use File::Temp qw(tempdir);
use Errno qw(EINTR);
my @live;
my $owner = $$;
my $directory;

=pod

Normalize an input string and validate decimal observations or worker counts.
Inputs: trim takes a scalar reference; valid and jobs take strings.
Outputs: trim updates its referent; valid returns a Boolean; jobs returns a count.
Used by: Latin run to clean lines and enforce the shared input contract.

=cut

=pod

Trim surrounding whitespace through a scalar reference.
Inputs: Reference to the caller string.
Outputs: Modified referent, no return contract.
Used by: Latin run before line classification.

=cut

sub trim { ${$_[0]} =~ s/^\s+|\s+$//g; }
=pod

Check complete decimal spelling, finiteness and the input domain.
Inputs: One input token.
Outputs: Boolean acceptance.
Used by: Latin run to skip malformed observations.

=cut

sub valid { $_[0] =~ /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/ &&
                    isfinite(0+$_[0]) && abs($_[0]) <= 1000 }
=pod

Convert a bounded worker-count argument.
Inputs: Decimal argument text.
Outputs: Integer 1..16, or an exception.
Used by: Latin run to limit process batches.

=cut

sub jobs { $_[0] =~ /^\d+$/ && $_[0] >= 1 && $_[0] <= 16 or die "workers must be 1..16\n"; 0+$_[0] }

=pod

Open, read, write, and close lexical handles with explicit error checks.
Inputs: paths for input/output; handles for readrow, emit, and shut; text for emit.
Outputs: handles, a line or undef at EOF, or a die exception on an I/O failure.
Used by: Latin run and its children for console/file input and ordered CSV.

=cut

=pod

Open the named input stream or borrow standard input.
Inputs: Path or dash.
Outputs: Lexical filehandle reference, or exception.
Used by: Latin run for original input and completed row files.

=cut

sub input { return \*STDIN if $_[0] eq '-'; open my $f, '<', $_[0] or die "open: $!\n"; $f }
=pod

Create a file for checked output.
Inputs: Target path.
Outputs: Writable lexical handle reference, or exception.
Used by: Latin workers and the parent CSV publisher.

=cut

sub output { open my $f, '>', $_[0] or die "open output: $!\n"; $f }
=pod

Read one line while distinguishing EOF from an I/O error.
Inputs: Readable handle.
Outputs: Line string, undef at EOF, or exception.
Used by: Latin run in both reading loops.

=cut

sub readrow { my $f=shift; $!=0; my $s=<$f>; die "read: $!\n" if !defined($s) && $!; $s }
=pod

Write a complete string through a handle reference.
Inputs: Writable handle and text.
Outputs: Written bytes, or exception.
Used by: Latin workers and the ordered CSV output loop.

=cut

sub emit { my ($f,$s)=@_; print {$f} $s or die "write: $!\n"; }
=pod

Close a file and check buffered writes.
Inputs: Handle reference.
Outputs: Closed stream, or exception.
Used by: Latin run and finish to complete I/O.

=cut

sub shut { close $_[0] or die "close: $!\n"; }

=pod

Provide process bookkeeping and a private path for each observation.
Inputs: track/reap take a PID; rowpath takes an ordinal; finish takes a handle.
Outputs: checked child completion, a path, or immediate successful child exit.
Used by: Latin run after fork, at batch boundaries, and when publishing rows.
The parent owns the temporary directory so a child's exit cannot remove it.

=cut

=pod

Name an observation file inside a private temporary directory.
Inputs: Observation ordinal.
Outputs: Unique per-run pathname.
Used by: Latin scheduler before forking and while gathering rows.

=cut

sub rowpath { $directory //= tempdir(CLEANUP=>0); "$directory/$_[0].csv" }
=pod

Record a child for cleanup if a later operation fails.
Inputs: Child PID.
Outputs: Updated live-child list.
Used by: Latin parent immediately after a successful fork.

=cut

sub track { push @live,$_[0]; }
=pod

Wait through interruptions and reject unsuccessful workers.
Inputs: Child PID.
Outputs: Reaped child and updated live list, or exception.
Used by: Latin parent at each bounded batch boundary.

=cut

sub reap {
    my $pid=shift; my $got;
    do { $got=waitpid($pid,0) } while $got<0 && $! == EINTR;
    die "worker $pid failed\n" if $got!=$pid || $?;
    @live=grep { $_!=$pid } @live;
}
=pod

Expose Perl fork, whose no-argument form lacks a Latin grammar rule.
Inputs: None.
Outputs: Child PID, zero in child, or undef on failure.
Used by: Latin run to branch into a numeric worker.

=cut

sub spawn { fork() }
=pod

Read the actual OS identity of this process.
Inputs: None.
Outputs: Numeric PID.
Used by: Latin worker when constructing its CSV row.

=cut

sub identity { $$ }
=pod

Provide a punctuation-leading CLI token to the Latin grammar.
Inputs: None.
Outputs: The --help string.
Used by: Latin run while recognizing usage requests.

=cut

sub help { "--help" }
=pod

Flush a worker row and exit without inherited stream cleanup.
Inputs: Worker output handle.
Outputs: Child process exits successfully; close errors throw.
Used by: Latin worker after emitting its observation.

=cut

sub finish { shut($_[0]); _exit(0); }

# The bootstrap catches exceptions thrown anywhere in the Latin program.
# Inputs: CLI/stdin. Outputs: CSV or stderr and nonzero status. Used by Perl startup.
my $ok=eval { run(); 1 };
my $error=$@;
if ($$ == $owner) {
    for (@live) { kill 'TERM',$_; waitpid($_,0); }
    if (defined $directory) { unlink glob "$directory/*.csv"; rmdir $directory; }
}
if (!$ok) { print STDERR "bessel: $error"; exit 1; }
exit 0;

use Lingua::Romana::Perligata;

ecce explico
Calculate J0 with midpoint quadrature entirely in Latin syntax.
Inputs: One validated real in haec (Perl's argument list).
Outputs: The average of 16384 samples as a floating-point scalar.
Used by: run's forked children to calculate their assigned observations.
ecce seco
observeere sic
    meis xo haec da.
    meo pio da unum tum unum angulamentum tum IV multiplicamentum.
    meo summao nullum da.
    meo indiceo nullum da.
    dum indiceum tum ((I))I))MCCCLXXXIV praestantiam fac sic
        adnota Form the midpoint angle, then evaluate its oscillating integrand.
        meo anguloo indiceum tum unum secundum addementum da.
        anguloo anguloum tum pium multiplicamentum tum ((I))I))MCCCLXXXIV dividementum da.
        meo termoo anguloum opponementum da.
        termoo termoum tum xum multiplicamentum da.
        termoo termoum accubamentum da.
        summao summaum tum termoum addementum da.
        indiceo postincresce.
    cis
    summaum tum ((I))I))MCCCLXXXIV dividementum redde.
cis

ecce explico
Run the public CLI and preserve input order across bounded process batches.
Inputs: parametra (ARGV), stdin or the selected file, and the helper interfaces.
Outputs: CSV rows or exceptions caught by the bootstrap; normal return is void.
Used by: the Perl bootstrap once at process startup.
ecce seco
runere sic
    meo argco parametra da.
    meo helppo helpementum da.
    si argcum tum unum aequalitam fac sic
      si nullimum parametrorum tum helppum aequalitas fac sic
        dictum sic Usage: perl bessel-perligata.pl [INPUT|- [OUTPUT [WORKERS]]] cis tum novumversum egresso scribe.
        nullum redde.
      cis
    cis
    si argcum tum IV non praestantiam fac sic dictum sic too many arguments cis mori. cis
    meo sourceo XLV indementum da.
    meo targeto dictum sic results.csv cis da.
    meo counto II da.
    si argcum tum unum non praestantiam fac sic sourceo nullimum parametrorum da. cis
    si argcum tum duo non praestantiam fac sic targeto primum parametrorum da. cis
    si argcum tum tres non praestantiam fac sic counto secundum parametrorum jobsementum da. cis
    meo ino sourceum inputementum da.
    meis valis.
    meo limito LXIV tum LXIV multiplicamentum da.
    meo textoo.
    dum unum fac sic
        textoo inum readrowementum da.
        nisi textoum confirmamentum fac sic ultimus. cis
        adnota Pass a scalar reference so trim can change the caller's string.
        meo refo da ad textoo.
        trime refum.
        si textoum metamentum tum nullum aequalitam fac sic ultimus. cis
        meo firsto textoum tum nullum tum unum excerpementum da.
        meo hasho XXXV indementum da.
        si firstum tum hashum aequalitas fac sic posterus. cis
        nisi textoum validementum fac sic dictum sic Skipping invalid value cis tum novumversum mone. posterus. cis
        valis textoum cumula.
        meo sizeo vala da.
        si limitum tum sizeum praestantiam fac sic dictum sic at most 4096 observations cis mori. cis
    cis
    shute inum.
    meo sizeo vala da.
    nisi sizeum fac sic dictum sic no valid observations cis mori. cis

    adnota Launch one child per observation, waiting after each full batch.
    meis pidis.
    meo indexo nullum da.
    dum indexum tum sizeum praestantiam fac sic
        meo patho indexum rowpathementum da.
        meo xo valis decapitamentum da.
        meo pido spawnementum da.
        nisi pidum confirmamentum fac sic dictum sic fork failed cis mori. cis
        nisi pidum fac sic
            meo yo xum observeementum da.
            meo outo pathum outputementum da.
            meo selfo identityementum da.
            meo texto xum tum comma tum yum tum comma tum selfum tum novumversum serementum da.
            emite outum tum textum.
            finishe outum.
        cis
        tracke pidum.
        pidis pidum cumula.
        indexo postincresce.
        meo activeo pida da.
        meo fullo activeum tum countum aequalitam da.
        meo doneo indexum tum sizeum aequalitam da.
        si fullum vel doneum fac sic
            per quisque childum in pidis fac sic reape childum. cis
            pidis iani.
        cis
    cis

    adnota Publish only completed rows, using explicit ordinals to restore order.
    meo outo targetum outputementum da.
    emite outum tum cum dictum sic x,j0,worker_pid cis tum novumversum serementum.
    indexo nullum da.
    dum indexum tum sizeum praestantiam fac sic
        meo rowo indexum rowpathementum inputementum da.
        meo texto rowum readrowementum da.
        emite outum tum textum.
        shute rowum.
        indexo postincresce.
    cis
    shute outum.
cis
