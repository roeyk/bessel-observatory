"Bessel Observatory: validate observations, compute J0 in separate OS workers, and save ordered CSV.
 The parent reads input and owns result ordering; the worker computes the midpoint approximation.
 An invalid observation is skipped with a warning, while failed I/O or workers abort the run."
"GNU Smalltalk 3.2+, POSIX. Messages, blocks, collections and ensure:.
 Run from this directory: gst -f bessel.st INPUT OUTPUT WORKERS.
 popen creates external GST VMs; Smalltalk block fork would only be a green process."

Object subclass: Observatory [
    "Expose the OS identity of the current GNU Smalltalk VM.
     Inputs: No explicit inputs.
     Outputs: The integer OS process ID.
     Used by: run: in worker mode when formatting its result row."
    Observatory class >> processId [
        <cCall: 'getpid' returning: #int args: #()>
    ]
    "Parse one complete numeric string and enforce the shared range.
     Inputs: A trimmed text string.
     Outputs: A bounded FloatD, or an Error.
     Used by: readValues: and run: before numerical work."
    Observatory class >> number: text [
        | stream x |
        text isEmpty ifTrue: [self error: 'expected a number'].
        (text allSatisfy: [:c | '0123456789+-.eE' includes: c])
            ifFalse: [self error: 'invalid numeric character'].
        (text anySatisfy: [:c | c isDigit]) ifFalse: [self error: 'expected digits'].
        "Use a stream position to ensure parsing consumed the entire token."
        stream := text readStream.
        x := (Number readFrom: stream) asFloatD.
        (stream atEnd and: [x >= -1000 and: [x <= 1000]])
            ifFalse: [self error: 'expected finite x in [-1000,1000]'].
        ^x
    ]
    "Convert a floating value to portable CSV scientific notation.
     Inputs: A numeric object.
     Outputs: Its printed text with a d exponent marker replaced by e.
     Used by: run: and batch: for CSV rows and worker arguments."
    Observatory class >> decimal: x [
        ^x printString copyReplaceAll: 'd' with: 'e'
    ]
    "Fold midpoint samples into the Bessel approximation.
     Inputs: One validated x.
     Outputs: The approximate J0 value.
     Used by: run: when executing in an external worker VM."
    Observatory class >> j0: x [
        ^((0 to: 16383) inject: 0.0d0 into: [:sum :k |
            sum + (x * ((FloatD pi * (k + 0.5d0) / 16384) sin)) cos]) / 16384
    ]
    "Collect usable observations while allowing malformed lines to be skipped.
     Inputs: A FileStream input.
     Outputs: An OrderedCollection of validated values.
     Used by: run: before process creation."
    Observatory class >> readValues: input [
        | values text done |
        values := OrderedCollection new. done := false.
        [input atEnd or: [done]] whileFalse: [
            text := input nextLine trimSeparators.
            text isEmpty ifTrue: [done := true] ifFalse: [
                text first = $# ifFalse: [
                    [values add: (self number: text)]
                        on: Error do: [:e | FileStream stderr nextPutAll: 'warning: invalid number; skipped'; nl].
                    values size > 4096 ifTrue: [self error: 'at most 4096 values']]]].
        values isEmpty ifTrue: [self error: 'no valid input values'].
        ^values
    ]
    "Open independent worker VMs and gather their rows in order.
     Inputs: A bounded collection of numeric values.
     Outputs: A collection of CSV row strings, or an Error after pipe cleanup.
     Used by: run: for each worker-sized slice."
    Observatory class >> batch: values [
        | pipes rows |
        "Retain every process pipe until collection or error cleanup finishes."
        pipes := OrderedCollection new. rows := OrderedCollection new.
        [values do: [:x |
            "Only a validated, re-formatted number enters the shell command."
            pipes add: (FileStream popen: ('gst -f bessel.st --worker ', (self decimal: x)) dir: FileStream read)].
         "Read results only after all pipes in the group have launched their external VMs."
         pipes do: [:pipe |
            | row |
            row := pipe nextLine.
            (row isNil or: [row isEmpty]) ifTrue: [self error: 'worker failed'].
            rows add: row]]
            ensure: [pipes do: [:pipe | pipe close]].
        ^rows
    ]
    "Implement help, worker calculation, and the full CLI workflow.
     Inputs: Smalltalk argument strings and optional standard input.
     Outputs: A result file and completion message, or an Error.
     Used by: The final on:do: guarded entry block."
    Observatory class >> run: args [
        | source target jobs input values rows output first last x |
        (args size = 1 and: [args first = '--help']) ifTrue: [
            FileStream stdout nextPutAll: 'Usage: gst -f bessel.st [INPUT|- [OUTPUT [WORKERS 1..16]]]'; nl. ^self].
        (args size = 2 and: [args first = '--worker']) ifTrue: [
            x := self number: args second.
            FileStream stdout nextPutAll: (self decimal: x); nextPut: $,;
                nextPutAll: (self decimal: (self j0: x)); nextPut: $,;
                nextPutAll: self processId printString; nl; flush. ^self].
        args size > 3 ifTrue: [self error: 'too many arguments'].
        source := args at: 1 ifAbsent: ['-'].
        target := args at: 2 ifAbsent: ['results.csv'].
        jobs := self number: (args at: 3 ifAbsent: ['2']).
        (jobs >= 1 and: [jobs <= 16 and: [jobs = jobs truncated]])
            ifFalse: [self error: 'workers must be 1..16'].
        jobs := jobs truncated.
        source = '-' ifTrue: [
            FileStream stderr nextPutAll: 'Enter one x per line; blank line or EOF finishes:'; nl.
            values := self readValues: FileStream stdin]
        ifFalse: [
            input := FileStream open: source mode: FileStream read.
            [values := self readValues: input] ensure: [input close]].
        rows := OrderedCollection new. first := 1.
        [first <= values size] whileTrue: [
            last := (first + jobs - 1) min: values size.
            rows addAll: (self batch: (values copyFrom: first to: last)).
            first := last + 1].
        "Create the output file after every group has returned its observations."
        output := FileStream open: target mode: FileStream write.
        [output nextPutAll: 'x,j0,worker_pid'; nl.
         rows do: [:row | output nextPutAll: row; nl]] ensure: [output close].
        FileStream stdout nextPutAll: 'Wrote '; nextPutAll: rows size printString;
            nextPutAll: ' observations to '; nextPutAll: target; nl
    ]
]
"Run the CLI behind a handler that turns runtime errors into readable failures."
[Observatory run: Smalltalk arguments]
    on: Error do: [:e |
        FileStream stderr nextPutAll: 'error: '; nextPutAll: e messageText; nl.
        ObjectMemory quit: 1].
