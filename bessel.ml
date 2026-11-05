(* Bessel Observatory: validate observations, compute J0 in separate OS workers, and save ordered CSV.
   The parent reads input and owns result ordering; the worker computes the midpoint approximation.
   An invalid observation is skipped with a warning, while failed I/O or workers abort the run. *)
(* OCaml 4.14+, Unix. Variants, pattern matching, lists, and Fun.protect. *)
(* Parse a complete float and reject unsupported classifications or magnitudes.
   Inputs: An input string.
   Outputs: A finite bounded float, or a conversion/domain exception.
   Used by: read_values while accepting observations. *)
let number text =
  let x = float_of_string (String.trim text) in
  match classify_float x with
  | FP_nan | FP_infinite -> invalid_arg "expected finite x in [-1000,1000]"
  | _ when abs_float x > 1000. -> invalid_arg "x outside [-1000,1000]"
  | _ -> x

(* Evaluate the midpoint integral using a local mutable accumulator.
   Inputs: A bounded float x.
   Outputs: The approximate J0 result.
   Used by: The child branch in batch. *)
let j0 x =
  let sum = ref 0. in
  for k = 0 to 16383 do
    sum := !sum +. cos (x *. sin (Float.pi *. (float k +. 0.5) /. 16384.))
  done;
  !sum /. 16384.

(* Read usable observations while isolating per-line conversion failures.
   Inputs: An input channel.
   Outputs: A nonempty-or-empty ordered list; the caller checks emptiness.
   Used by: run before it creates children. *)
let read_values channel =
  (* Continue reading with an explicit accepted-value count.
     Inputs: Reverse-order values and their count; channel is captured.
     Outputs: The ordered values at EOF/blank line, or a fatal size-limit error.
     Used by: read_values and its own recursive call. *)
  let rec loop acc n =
    match input_line channel with
    | line ->
      let text = String.trim line in
      if text = "" then List.rev acc
      else if text.[0] = '#' then loop acc n
      else (
        let value = try Some (number text) with Failure _ | Invalid_argument _ -> None in
        match value with
        | None -> prerr_endline "warning: invalid number; skipped"; loop acc n
        | Some x -> if n = 4096 then failwith "at most 4096 values" else loop (x :: acc) (n + 1))
    | exception End_of_file -> List.rev acc
  in loop [] 0

(* Start bounded child processes and return their rows in input order.
   Inputs: A list of validated values.
   Outputs: CSV rows; errors propagate after channels and PIDs are cleaned up.
   Used by: The compute helper inside run. *)
let batch values =
  let children = ref [] in
  (* Tie channel closure and child reaping to the batch scope on both success and failure. *)
  Fun.protect ~finally:(fun () ->
    List.iter (fun (pid, channel) ->
      close_in_noerr channel;
      try ignore (Unix.waitpid [] pid) with Unix.Unix_error (Unix.ECHILD, _, _) -> ()) !children)
    (fun () ->
      List.iter (fun x ->
        let reader, writer = Unix.pipe () in
        let pid = try Unix.fork () with e -> Unix.close reader; Unix.close writer; raise e in
        (* Perform numerical work only in the forked child, then terminate without running parent logic. *)
        if pid = 0 then (
          Unix.close reader;
          let output = Unix.out_channel_of_descr writer in
          try
            Printf.fprintf output "%.17g,%.17g,%d\n" x (j0 x) (Unix.getpid ());
            close_out output; Unix._exit 0
          with _ -> Unix._exit 1);
        Unix.close writer;
        children := (pid, Unix.in_channel_of_descr reader) :: !children) values;
      (* Collect results only after every child in the group has been launched. *)
      List.map (fun (pid, channel) ->
        let row = input_line channel in
        match Unix.waitpid [] pid with
        | _, Unix.WEXITED 0 -> row ^ "\n"
        | _ -> failwith "worker failed") (List.rev !children))

(* Split off one bounded prefix without losing list order.
   Inputs: A count, reverse prefix accumulator and remaining list.
   Outputs: The prefix and unconsumed suffix.
   Used by: compute when forming process groups. *)
let rec take n acc xs = match n, xs with
  | 0, _ | _, [] -> List.rev acc, xs
  | _, x :: rest -> take (n - 1) (x :: acc) rest

(* Implement help, CLI parsing, input processing and result output.
   Inputs: Argument strings without the executable name.
   Outputs: A result file and completion message, or an exception.
   Used by: The final entry expression. *)
let run args = match args with
  | ["--help"] -> print_endline "Usage: bessel-ocaml [INPUT|- [OUTPUT [WORKERS 1..16]]]"
  | _ ->
    let source, target, jobs = match args with
      | [] -> "-", "results.csv", 2
      | [s] -> s, "results.csv", 2
      | [s;t] -> s,t,2
      | [s;t;j] -> s,t,int_of_string j
      | _ -> invalid_arg "too many arguments" in
    if jobs < 1 || jobs > 16 then invalid_arg "workers must be 1..16";
    let values = if source = "-" then (
      prerr_endline "Enter one x per line; blank line or EOF finishes:"; read_values stdin)
    else let input = open_in source in
      Fun.protect ~finally:(fun () -> close_in_noerr input) (fun () -> read_values input) in
    if values = [] then invalid_arg "no valid input values";
    (* Process one bounded group at a time and accumulate its rows.
       Inputs: Prior groups and the remaining observations; jobs is captured.
       Outputs: The flattened rows in original input order.
       Used by: run after read_values succeeds. *)
    let rec compute acc = function
      | [] -> List.rev acc |> List.concat
      | xs -> let group, rest = take jobs [] xs in compute (batch group :: acc) rest in
    let rows = compute [] values in
    (* Create output after all child batches have succeeded. *)
    let output = open_out target in
    Fun.protect ~finally:(fun () -> close_out_noerr output) (fun () ->
      output_string output "x,j0,worker_pid\n";
      List.iter (output_string output) rows; flush output);
    Printf.printf "Wrote %d observations to %s\n" (List.length rows) target

(* Turn a fatal exception into one readable diagnostic and a failure exit. *)
let () = try run (Array.to_list Sys.argv |> List.tl) with e ->
  prerr_endline ("error: " ^ Printexc.to_string e); exit 1
