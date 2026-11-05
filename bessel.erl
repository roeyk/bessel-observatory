#!/usr/bin/env escript
%%! +S 1:1 +A 1
%% Bessel Observatory: validate observations, compute J0 in separate OS workers, and save ordered CSV.
%% The parent reads input and owns result ordering; the worker computes the midpoint approximation.
%% An invalid observation is skipped with a warning, while failed I/O or workers abort the run.
%% Erlang/OTP 25+: pattern matching, tail recursion, ports and mailbox messages.
%% Each port runs another OS VM. BEAM spawn alone would not meet the OS-process goal.
-mode(compile).

%% Provide the escript entry point and final exception boundary.
%% Inputs: The CLI argument list.
%% Outputs: Successful output or a readable diagnostic followed by failure status.
%% Used by: The escript runtime.
main(Args) ->
    try run(Args)
    catch Class:Reason -> io:format(standard_error, "error: ~p: ~p~n", [Class, Reason]), halt(1)
    end.

%% Parse an integer or floating token and enforce the supported range.
%% Inputs: A trimmed or untrimmed numeric character list.
%% Outputs: A bounded float, or an Erlang error.
%% Used by: run and read_values before any numerical work.
number(Text) ->
    X = case string:to_float(string:trim(Text)) of
        {F, []} -> F;
        _ -> case string:to_integer(string:trim(Text)) of
            {I, []} -> float(I);
            _ -> error(invalid_number)
        end
    end,
    case abs(X) =< 1000 of true -> X; false -> error(out_of_range) end.

%% Initialize and normalize the midpoint accumulation.
%% Inputs: One validated x.
%% Outputs: The approximate J0 value.
%% Used by: run in the independent worker VM.
j0(X) -> j0(X, 0, 0.0) / 16384.
%% Accumulate the integral using tail recursion rather than mutable loop state.
%% Inputs: The input x, current sample index, and accumulated sum.
%% Outputs: The completed unnormalized sample sum.
%% Used by: j0/1 and its own recursive step.
j0(_, 16384, Sum) -> Sum;
j0(X, K, Sum) -> j0(X, K + 1, Sum + math:cos(X * math:sin(math:pi() * (K + 0.5) / 16384))).

%% Start collecting observations from an IO device.
%% Inputs: A file device or standard_io.
%% Outputs: An ordered list of accepted numbers.
%% Used by: run in parent mode.
read_values(Device) -> read_values(Device, [], 0).
%% Classify lines and retain accepted values with a bounded count.
%% Inputs: The input device, reverse-order values and accepted count.
%% Outputs: The ordered values at blank line/EOF, or a fatal input error.
%% Used by: read_values/1 and its recursive continuation.
read_values(Device, Acc, N) ->
    case io:get_line(Device, "") of
        eof -> lists:reverse(Acc);
        {error, Reason} -> error({input, Reason});
        Line -> case string:trim(Line) of
            [] -> lists:reverse(Acc);
            [$# | _] -> read_values(Device, Acc, N);
            Text ->
                %% Catch numeric conversion failures locally so later input lines remain usable.
                Parsed = try {ok, number(Text)} catch error:_ -> invalid end,
                case Parsed of
                    {ok, _} when N >= 4096 -> error(too_many_values);
                    {ok, X} -> read_values(Device, [X | Acc], N + 1);
                    invalid -> io:format(standard_error, "warning: invalid number; skipped~n", []),
                               read_values(Device, Acc, N)
                end
        end
    end.

%% Receive one worker response until its exit status is known.
%% Inputs: A port handle and reverse-order output chunks.
%% Outputs: The complete worker output, or a failure/timeout error.
%% Used by: launch after all ports in the batch are open.
collect(Port, Chunks) ->
    receive
        {Port, {data, Bytes}} -> collect(Port, [Bytes | Chunks]);
        {Port, {exit_status, 0}} when Chunks =/= [] -> lists:reverse(Chunks);
        {Port, {exit_status, Code}} -> error({worker_failed, Code})
    %% Bound the wait for a worker that failed to return a result or exit status.
    after 30000 -> error(worker_timeout)
    end.

%% Initialize a group of independent worker VMs.
%% Inputs: A bounded list of x values.
%% Outputs: Rows in original value order.
%% Used by: compute for each worker-sized group.
batch(Values) -> launch(Values, []).
%% Hold port ownership while starting workers and collecting their results.
%% Inputs: Remaining values and the ports already started.
%% Outputs: All rows, with every port closed during scope unwinding.
%% Used by: batch and recursive launch calls.
launch([], Ports) -> [collect(P, []) || P <- lists:reverse(Ports)];
launch([X | Rest], Ports) ->
    %% Create an OS VM process; ordinary BEAM spawn alone would not create a separate OS process.
    Port = open_port({spawn_executable, os:find_executable("escript")},
        [binary, use_stdio, exit_status,
         {args, [filename:absname(escript:script_name()), "--worker", float_to_list(X, [short])]}]),
    try launch(Rest, [Port | Ports])
    after try port_close(Port) catch error:badarg -> ok end
    end.

%% Split input into bounded groups and concatenate their ordered results.
%% Inputs: The remaining values and maximum worker count.
%% Outputs: An IO-list of completed CSV rows.
%% Used by: run after input validation.
compute([], _) -> [];
compute(Values, Jobs) ->
    {Group, Rest} = lists:split(min(Jobs, length(Values)), Values),
    [batch(Group) | compute(Rest, Jobs)].

%% Select help, worker computation, or the complete CLI experiment.
%% Inputs: A list of argument strings.
%% Outputs: CSV/console output, or an error caught by main.
%% Used by: main for every parent or child invocation.
run(["--help"]) -> io:format("Usage: escript bessel.erl [INPUT|- [OUTPUT [WORKERS 1..16]]]~n");
run(["--worker", Text]) ->
    X = number(Text), io:format("~.17g,~.17g,~s~n", [X, j0(X), os:getpid()]);
run(Args) when length(Args) =< 3 ->
    {Source, Target, Jobs} = case Args of
        [] -> {"-", "results.csv", 2};
        [S] -> {S, "results.csv", 2};
        [S, T] -> {S, T, 2};
        [S, T, J] -> {S, T, list_to_integer(J)}
    end,
    (Jobs >= 1 andalso Jobs =< 16) orelse error(invalid_worker_count),
    Values = case Source of
        "-" -> io:format(standard_error, "Enter one x per line; blank line or EOF finishes:~n", []),
               read_values(standard_io);
        _ -> {ok, Input} = file:open(Source, [read]),
             try read_values(Input) after file:close(Input) end
    end,
    Values =/= [] orelse error(no_valid_input),
    Rows = compute(Values, Jobs),
    %% Write ordered rows only after all worker groups have returned successfully.
    ok = file:write_file(Target, ["x,j0,worker_pid\n", Rows]),
    io:format("Wrote ~B observations to ~s~n", [length(Values), Target]);
run(_) -> error(too_many_arguments).
