#!/usr/bin/env perl
use FindBin qw($RealBin);
use lib $RealBin;
use BesselPerligata;
use Lingua::Romana::Perligata;

ecce explico
Bessel Observatory, expressed in Perligata's modified Latin grammar.
The calculation, file opening/writing/closing, argument handling, string
assembly and bounded worker orchestration below all use the Latin notation.
BesselPerligata.pm supplies documented regex, raw-read and OS services; its
source has a separate highlighted link in the catalogue.

Vocabulary: numerum is an observation, summum a sum, angulum an angle,
terminum a term, indicum an index, librum an open book (file handle),
fontum the source, destinatum the destination, filium a child process,
observata the accepted observations, and vinculum a reference (a bond).
Perligata regularizes all nouns and user verbs; these are Latin roots under
its grammar, rather than a claim to unrestricted classical Latin.

An -o ending marks a scalar destination; -um marks its value. Arrays use
-is and -a respectively. Verbs such as da, scribe and claude state the action.
English functional comments explain what each sentence or paragraph achieves.
ecce seco

ecce explico
pendere (weigh): calculate J0 by averaging midpoint samples of its integral.
Inputs: one validated observation in haec, the argument list.
Outputs: floating-point J0 approximation using 16384 samples.
Used by: agere's children to do the numerical work locally in Latin syntax.
ecce seco
pendere sic
    meis numero haec da.
    meo pio da unum tum unum angulamentum tum IV multiplicamentum.
    meo summo nullum da.
    meo indico nullum da.
    dum indicum tum ((I))I))MCCCLXXXIV praestantiam fac sic
        adnota Form the midpoint angle, then cos(x sin(angle)), and accumulate it.
        meo angulo indicum tum unum secundum addementum da.
        angulo angulum tum pium multiplicamentum tum ((I))I))MCCCLXXXIV dividementum da.
        meo termino angulum opponementum da.
        termino terminum tum numerum multiplicamentum da.
        termino terminum accubamentum da.
        summo summum tum terminum addementum da.
        indico postincresce.
    cis
    summum tum ((I))I))MCCCLXXXIV dividementum redde.
cis

ecce explico
pandere (open): obtain a checked lexical filehandle using native evolute.
Inputs: open mode and path, or descriptor zero with mode less-than-ampersand.
Outputs: owning handle reference, or exception on failure.
Used by: agere to open observations, private rows and final CSV output.
Three-argument open treats a path as a filename, never a shell command.
ecce seco
pandere sic
    meo modo his decapitamentum da.
    meo viao his decapitamentum da.
    meo libro.
    nisi libro modum tum viaum evolutementum fac sic
        dictum sic Cannot open file: cis tum stadium tum viaum tum novumversum mori.
    cis
    librum redde.
cis

ecce explico
fundere (pour): write a complete string using native scribe and check success.
Inputs: writable handle reference and text. Outputs: written text or exception.
Used by: agere's workers for rows and the parent for ordered CSV publication.
The caller closes the handle separately to check delayed buffered-write errors.
ecce seco
fundere sic
    meo libro his decapitamentum da.
    meo textoo his decapitamentum da.
    nisi libro textoum scribementum fac sic
        dictum sic Cannot write output cis tum novumversum mori.
    cis
cis

ecce explico
agere (act): read observations, schedule bounded workers, and publish CSV.
Inputs: parametra (ARGV), stdin or the selected file, and compatibility services.
Outputs: ordered CSV or an exception; normal return carries no result.
Used by: tege agtorem at startup, which catches errors and cleans child resources.
An ad reference lets tergere trim the caller's string in place. Perl retains
that scalar while the reference exists; raw pointer arithmetic is unavailable.
ecce seco
agere sic
    adnota Recognize help, reject excess arguments, and apply the public defaults.
    meo copio parametra da.
    meo signo XLV indementum da.
    meo auxilio signum tum signum tum dictum sic help cis serementum da.
    si copium tum unum aequalitam fac sic
        si nullimum parametrorum tum auxilium aequalitas fac sic
            dictum sic Usage: perl bessel-perligata.pl [INPUT|- [OUTPUT [WORKERS]]] cis tum novumversum egresso scribe.
            nullum redde.
        cis
    cis
    si copium tum IV non praestantiam fac sic
        dictum sic too many arguments cis mori.
    cis
    meo fonto signum da.
    meo destinato dictum sic results.csv cis da.
    meo opero II da.
    si copium tum unum non praestantiam fac sic fonto nullimum parametrorum da. cis
    si copium tum duo non praestantiam fac sic destinato primum parametrorum da. cis
    si copium tum tres non praestantiam fac sic opero secundum parametrorum regementum da. cis

    adnota Build open modes from characters; duplicate stdin for the dash input.
    meo legendo LX indementum da.
    meo scribendo LXII indementum da.
    si fontum tum signum aequalitas fac sic
        legendo legendum tum cum XXXVIII indementum serementum da.
        fonto nullum da.
    cis
    meo libro legendum tum fontum pandementum da.
    meis observatis.
    meo fino LXIV tum LXIV multiplicamentum da.
    meo textoo.
    dum unum fac sic
        adnota Preserve original input bytes; native perlege would translate Roman numerals.
        textoo librum accipementum da.
        nisi textoum confirmamentum fac sic ultimus. cis
        meo vinculo da ad textoo.
        terge vinculum.
        si textoum metamentum tum nullum aequalitam fac sic ultimus. cis
        adnota Inspect the first character after trimming, then validate decimal spelling.
        meo capito textoum tum nullum tum unum excerpementum da.
        meo noto XXXV indementum da.
        si capitum tum notum aequalitas fac sic posterus. cis
        nisi textoum probementum fac sic
            dictum sic Skipping invalid value cis tum novumversum mone.
            posterus.
        cis
        observatis textoum cumula.
        meo copio observata da.
        si finum tum copium praestantiam fac sic
            dictum sic at most 4096 observations cis mori.
        cis
    cis
    nisi libro claudementum fac sic dictum sic Cannot close input cis mori. cis
    meo copio observata da.
    nisi copium fac sic dictum sic no valid observations cis mori. cis

    adnota Start one OS child per observation, waiting after each bounded batch.
    meis filiis.
    meo indico nullum da.
    dum indicum tum copium praestantiam fac sic
        meo viao indicum locementum da.
        meo numero observatis decapitamentum da.
        meo filio gignementum da.
        nisi filium fac sic
            adnota Calculate in this child, assemble one CSV row and close it before exit.
            meo responso numerum pendementum da.
            meo libro scribendum tum viaum pandementum da.
            meo proprio cognoscementum da.
            meo textoo numerum tum comma tum responsum tum comma tum proprium tum novumversum serementum da.
            funde librum tum textoum.
            nisi libro claudementum fac sic dictum sic Cannot close worker row cis mori. cis
            discede.
        cis
        filiis filium cumula.
        indico postincresce.
        meo vivo filia da.
        meo pleno vivum tum operum aequalitam da.
        meo ultimo indicum tum copium aequalitam da.
        si plenum vel ultimum fac sic
            per quisque filium in filiis fac sic collige filium. cis
            filiis iani.
        cis
    cis

    adnota Publish only successful rows, restoring input order through their ordinals.
    legendo LX indementum da.
    libro scribendum tum destinatum pandementum da.
    funde librum tum cum dictum sic x,j0,worker_pid cis tum novumversum serementum.
    indico nullum da.
    dum indicum tum copium praestantiam fac sic
        meo viao indicum locementum da.
        meo paginao legendum tum viaum pandementum da.
        meo textoo paginaum accipementum da.
        funde librum tum textoum.
        nisi paginao claudementum fac sic dictum sic Cannot close worker row cis mori. cis
        indico postincresce.
    cis
    nisi libro claudementum fac sic dictum sic Cannot close output cis mori. cis
cis

adnota Protect the whole run by passing a code reference to the exception boundary.
tege agtorem.
