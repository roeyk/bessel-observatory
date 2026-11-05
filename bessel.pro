/*
  Bessel Observatory: validate observations, compute J0 in separate OS workers, and save ordered CSV.
  The parent reads input and owns result ordering; the worker computes the midpoint approximation.
  An invalid observation is skipped with a warning, while failed I/O or workers abort the run.
  SWI-Prolog 9.x: relations, recursive folds, catch/3, setup_call_cleanup/3.
*/
:- use_module(library(readutil)).
:- use_module(library(process)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- dynamic script_path/1.
:- prolog_load_context(file, File), assertz(script_path(File)).
:- initialization(main, main).

/*
  Relate a complete numeric string to one bounded observation.
  Inputs: Text is the candidate token; X is initially unbound.
  Outputs: X becomes a finite numeric value, or validation fails/throws.
  Used by: read_values and the worker clause of run.
*/
number(Text, X) :-
    \+ sub_string(Text, _, 1, _, " "), % number_string/2 otherwise accepts embedded spaces
    number_string(N, Text), X is float(N),
    (X >= -1000, X =< 1000 -> true ; throw(error(domain_error(bounded_real, Text), _))).

/*
  Relate an input observation to its normalized Bessel approximation.
  Inputs: A validated numeric X and an output variable Y.
  Outputs: Y is unified with the midpoint result.
  Used by: The worker clause of run.
*/
j0(X, Y) :- integrate(0, X, 0.0, Sum), Y is Sum / 16384.
/*
  Accumulate midpoint samples through tail recursion.
  Inputs: The sample index, X, running total, and result variable.
  Outputs: The final unnormalized sum.
  Used by: j0 and recursive integrate calls.
*/
integrate(16384, _, Sum, Sum) :- !.
integrate(K, X, Acc, Sum) :-
    Next is K + 1,
    Total is Acc + cos(X * sin(pi * (K + 0.5) / 16384)),
    integrate(Next, X, Total, Sum).

/*
  Start collecting observations from a stream.
  Inputs: A readable stream and an output list variable.
  Outputs: Values is unified with the accepted input in original order.
  Used by: run for both file and interactive input.
*/
read_values(Stream, Values) :- read_values(Stream, [], 0, Values).
/*
  Read and classify the next line with explicit accumulated state.
  Inputs: The stream, reversed accepted values, count and final result variable.
  Outputs: The final ordered list, or a fatal input-limit condition.
  Used by: read_values/2 and recursive calls.
*/
read_values(Stream, Acc, Count, Values) :-
    read_line_to_string(Stream, Line),
    ( Line == end_of_file -> reverse(Acc, Values)
% Normalize user whitespace before classifying blank lines, comments and numeric tokens.
    ; normalize_space(string(Text), Line),
      ( Text == "" -> reverse(Acc, Values)
      ; sub_string(Text, 0, 1, _, "#") -> read_values(Stream, Acc, Count, Values)
      ; (catch(number(Text, X), _, fail) ->
          (Count < 4096 -> Next is Count + 1, read_values(Stream, [X|Acc], Next, Values)
          ; throw(error(resource_error(input_limit), _)))
        ; format(user_error, 'warning: invalid number; skipped~n', []), read_values(Stream, Acc, Count, Values))
      )
    ).

/*
  Create a separate SWI-Prolog process for one numerical observation.
  Inputs: A validated X and an output worker descriptor.
  Outputs: A descriptor holding the child PID and output stream.
  Used by: launch through setup_call_cleanup.
*/
start_worker(X, worker(Pid, Stream)) :-
    script_path(Script), format(atom(Text), '~17g', [X]),
    current_prolog_flag(executable, Executable),
    process_create(Executable, ['-q', '-s', Script, '--', '--worker', Text],
                   [stdin(null), stdout(pipe(Stream)), process(Pid)]).
/*
  Close the output stream and reap any remaining child.
  Inputs: A worker descriptor.
  Outputs: Cleanup effects; already-cleaned resources are tolerated.
  Used by: setup_call_cleanup on both success and exception paths.
*/
cleanup_worker(worker(Pid, Stream)) :-
    catch(close(Stream), _, true),
    catch(process_wait(Pid, _), _, true).
/*
  Receive a complete result and require successful child termination.
  Inputs: A worker descriptor and row output variable.
  Outputs: One CSV string, or a worker_failed exception.
  Used by: launch after all children have been started.
*/
collect(worker(Pid, Stream), Row) :-
    read_string(Stream, _, Row), process_wait(Pid, Status),
    (Status == exit(0), Row \== "" -> true ; throw(error(worker_failed(Status), _))).
/*
  Keep worker lifetimes scoped while launching and gathering a whole group.
  Inputs: Remaining values, pending worker descriptors, and result rows.
  Outputs: Rows in original order; cleanup is guaranteed around nested calls.
  Used by: compute and recursive launch calls.
*/
launch([], Pending, Rows) :- reverse(Pending, Ordered), maplist(collect, Ordered, Rows).
launch([X|Xs], Pending, Rows) :-
    % Keep the child resource lifetime around the rest of this batch, including failures.
    setup_call_cleanup(start_worker(X, Worker), launch(Xs, [Worker|Pending], Rows), cleanup_worker(Worker)).

/*
  Split a list into one bounded prefix and its remainder.
  Inputs: A limit and remaining values; the last two arguments are outputs.
  Outputs: A prefix list and the unconsumed suffix.
  Used by: compute to implement bounded concurrency.
*/
take(0, Xs, [], Xs) :- !.
take(_, [], [], []) :- !.
take(N, [X|Xs], [X|Front], Rest) :- Next is N - 1, take(Next, Xs, Front, Rest).
/*
  Run consecutive groups of observations without changing their order.
  Inputs: Remaining values, worker limit, and result-list variable.
  Outputs: All CSV rows, or a propagated worker exception.
  Used by: run after input is validated.
*/
compute([], _, []) :- !.
compute(Values, Jobs, Rows) :-
    take(Jobs, Values, Group, Rest), launch(Group, [], Batch),
    compute(Rest, Jobs, Tail), append(Batch, Tail, Rows).

/*
  Relate positional CLI forms to their defaults.
  Inputs: An argument list; source, target and jobs are outputs.
  Outputs: One normalized option tuple, or failure for an unsupported form.
  Used by: run before file I/O or worker creation.
*/
options([], '-', 'results.csv', 2).
options([Source], Source, 'results.csv', 2).
options([Source,Target], Source, Target, 2).
options([Source,Target,Text], Source, Target, Jobs) :- atom_number(Text, Jobs).

/*
  Select help, worker computation, or the parent workflow by pattern.
  Inputs: The command-line argument list.
  Outputs: CSV/console effects, or an exception for a fatal error.
  Used by: main as the common invocation dispatcher.
*/
run(['--help']) :- !,
    writeln('Usage: swipl -q -s bessel.pro -- [INPUT|- [OUTPUT [WORKERS 1..16]]]').
run(['--worker', Text]) :- !,
    atom_string(Text, String), number(String, X), j0(X, Y), current_prolog_flag(pid, Pid),
    format('~17g,~17g,~d~n', [X, Y, Pid]).
run(Args) :-
    (options(Args, Source, Target, Jobs), integer(Jobs), between(1,16,Jobs) -> true
    ; throw(error(domain_error(arguments, Args), _))),
    (Source == '-' ->
        format(user_error, 'Enter one x per line; blank line or EOF finishes:~n', []),
        read_values(user_input, Values)
    ; setup_call_cleanup(open(Source, read, Input), read_values(Input, Values), close(Input))),
    (Values == [] -> throw(error(domain_error(nonempty_input, Values), _)) ; true),
    % Complete all numerical batches before opening the output file.
    compute(Values, Jobs, Rows),
    setup_call_cleanup(open(Target, write, Output),
% Write rows in their already-preserved input sequence.
        (format(Output, 'x,j0,worker_pid~n', []), forall(member(Row, Rows), format(Output, '~s', [Row]))),
        close(Output)),
    length(Rows, Count), format('Wrote ~d observations to ~w~n', [Count, Target]).

/*
  Bridge Prolog success/failure semantics to a command-line exit status.
  Inputs: The argv process flag.
  Outputs: Success or a readable diagnostic followed by status 1.
  Used by: The initialization directive when the file is launched.
*/
main :- current_prolog_flag(argv, Args),
    catch((run(Args) -> true ; throw(error(program_failed, _))),
          Error, (format(user_error, 'error: ~w~n', [Error]), halt(1))).
