(* Bessel Observatory for Oxford Oberon-2 (OBC 3).
   The module owns validation, scheduling, and mathematics. Its small C adapter
   supplies checked POSIX and stdio calls absent from Oberon-2's core language.
   Run: build/bessel-oberon [INPUT|- [OUTPUT [WORKERS]]]. *)
MODULE Bessel;
IMPORT Args, MathL, SYSTEM;
CONST Samples = 16384; Limit = 4096;
TYPE
  Observation = POINTER TO RECORD x, y: LONGREAL; pid: INTEGER END;
  Buffer = POINTER TO RECORD data: ARRAY Samples OF LONGREAL END;
VAR
  values: ARRAY Limit OF Observation;
  source, target, text: ARRAY 4096 OF CHAR;
  count, workers, length, i, base, slot, batch, pid: INTEGER;
  x: LONGREAL;

(* Message prints a diagnostic or progress line. Inputs: text, stderr flag.
   Output: terminal text. Used by Main and Fail for readable messages. *)
PROCEDURE Message(text: ARRAY OF CHAR; error: INTEGER) IS "bo_message";

(* OpenInput opens a file or stdin. Input: NUL-terminated path.
   Output: success flag. Used by Main before its reading loop. *)
PROCEDURE OpenInput(path: ARRAY OF CHAR): INTEGER IS "bo_input";
(* ReadLine fills a bounded buffer. Input: buffer and capacity.
   Output: length, -1 at EOF, -2 on failure. Used by Main to read observations. *)
PROCEDURE ReadLine(VAR line: ARRAY OF CHAR; capacity: INTEGER): INTEGER IS "bo_line";
(* Parse converts a complete token with range checks. Inputs: text, VAR result.
   Output: success flag and double. Used by Main after whitespace trimming. *)
PROCEDURE Parse(line: ARRAY OF CHAR; VAR value: LONGREAL): INTEGER IS "bo_parse";
(* Pipe creates one IPC slot. Input: slot ordinal. Output: success flag.
   Used by Main before forking its corresponding calculation. *)
PROCEDURE Pipe(slot: INTEGER): INTEGER IS "bo_pipe";
(* Fork starts a process. Input: slot. Output: child PID, zero in child, or -1.
   Used by Main to branch between scheduling and numerical work. *)
PROCEDURE Fork(slot: INTEGER): INTEGER IS "bo_fork";
(* Send publishes a child's answer and exits that child.
   Inputs: slot and result. Output: process status. Used by the worker branch. *)
PROCEDURE Send(slot: INTEGER; value: LONGREAL) IS "bo_send";
(* Collect reads and reaps a worker. Inputs: slot and VAR result.
   Outputs: success flag and answer. Used by Main at each batch boundary. *)
PROCEDURE Collect(slot: INTEGER; VAR value: LONGREAL): INTEGER IS "bo_collect";
(* Cleanup closes open streams and reaps remaining children.
   Inputs: adapter-owned state. Output: none. Used by Fail and normal shutdown. *)
PROCEDURE Cleanup IS "bo_cleanup";
(* OpenOutput creates the CSV and writes its header. Input: path.
   Output: success flag. Used by Main after every observation has succeeded. *)
PROCEDURE OpenOutput(path: ARRAY OF CHAR): INTEGER IS "bo_output";
(* Row formats one observation. Inputs: x, y, child PID. Output: success flag.
   Used by Main to publish observations in their original input order. *)
PROCEDURE Row(x, y: LONGREAL; pid: INTEGER): INTEGER IS "bo_row";
(* CloseOutput checks buffered writes. Input: adapter stream. Output: success.
   Used by Main before reporting completion. *)
PROCEDURE CloseOutput(): INTEGER IS "bo_close_output";

(* Fail reports a fatal error without a low-level assertion failure.
   Input: diagnostic string. Output: stderr, resource cleanup, exit status 1.
   Used by Main for invalid arguments and by all OS-operation checks. *)
PROCEDURE Fail(message: ARRAY OF CHAR);
BEGIN
  Message(message, 1);
  Cleanup; HALT(1)
END Fail;

(* Trim changes a caller-owned string through a VAR reference.
   Input: NUL-terminated line. Output: the line without surrounding whitespace.
   Used by Main to recognize blank lines and leading comment markers. *)
PROCEDURE Trim(VAR line: ARRAY OF CHAR);
  VAR first, last, j: INTEGER;
BEGIN
  last := 0;
  WHILE line[last] # 0X DO INC(last) END;
  WHILE (last > 0) & (line[last-1] <= " ") DO DEC(last) END;
  first := 0;
  WHILE (first < last) & (line[first] <= " ") DO INC(first) END;
  FOR j := first TO last-1 DO line[j-first] := line[j] END;
  line[last-first] := 0X
END Trim;

(* WorkerCount accepts an unsigned decimal count and rejects partial parses.
   Input: argument text. Output: integer 1..16 or a readable fatal error.
   Used by Main to bound simultaneous child processes. *)
PROCEDURE WorkerCount(line: ARRAY OF CHAR): INTEGER;
  VAR n, j: INTEGER;
BEGIN
  n := 0; j := 0;
  WHILE line[j] # 0X DO
    IF (line[j] < "0") OR (line[j] > "9") OR (j > 8) THEN
      Fail("workers must be an integer from 1 to 16")
    END;
    n := n*10 + ORD(line[j])-ORD("0");
    IF n > 16 THEN Fail("workers must be from 1 to 16") END;
    INC(j)
  END;
  IF n < 1 THEN Fail("workers must be from 1 to 16") END;
  RETURN n
END WorkerCount;

(* J0 evaluates the common quadrature with LONGREAL arithmetic.
   Input: finite x in [-1000,1000]. Output: approximate Bessel J0(x).
   Used by: the forked worker branch; never by the parent scheduler.
   The typed pointer owns its buffer. Raw byte addresses are used only while
   that buffer remains live; no allocation occurs during the address walk. *)
PROCEDURE J0(x: LONGREAL): LONGREAL;
  VAR buffer: Buffer; k, address: INTEGER; sum, term: LONGREAL;
BEGIN
  NEW(buffer);
  FOR k := 0 TO Samples-1 DO
    buffer.data[k] := MathL.Cos(x*MathL.Sin(MathL.pi*(k+0.5D0)/Samples))
  END;
  address := SYSTEM.ADR(buffer.data[0]); sum := 0.0D0; term := 0.0D0;
  FOR k := 0 TO Samples-1 DO
    SYSTEM.GET(address, term);
    sum := sum + term;
    INC(address, SIZE(LONGREAL))  (* Advance by one double's byte width. *)
  END;
  RETURN sum/Samples
END J0;

(* Main: parse arguments, retain accepted observations, run bounded batches,
   and export completed rows. The module loader invokes this initialization. *)
BEGIN
  IF Args.argc = 2 THEN
    Args.GetArg(1, text);
    IF text = "--help" THEN
      Message("Usage: bessel-oberon [INPUT|- [OUTPUT [WORKERS]]]", 0);
      HALT(0)
    END
  END;
  IF Args.argc > 4 THEN Fail("too many arguments") END;
  source := "-"; target := "results.csv"; workers := 2;
  IF Args.argc > 1 THEN Args.GetArg(1, source) END;
  IF Args.argc > 2 THEN Args.GetArg(2, target) END;
  IF Args.argc > 3 THEN Args.GetArg(3, text); workers := WorkerCount(text) END;
  IF OpenInput(source) = 0 THEN Fail("cannot open input") END;
  count := 0;
  LOOP
    length := ReadLine(text, LEN(text));
    IF length = -1 THEN EXIT END;
    IF length < -1 THEN Fail("input read failed or line exceeds 4095 bytes") END;
    Trim(text);
    IF text[0] = 0X THEN EXIT END;
    IF text[0] # "#" THEN
      IF Parse(text, x) = 0 THEN
        Message("Skipping invalid value:", 1); Message(text, 1)
      ELSE
        IF count = Limit THEN Fail("at most 4096 observations") END;
        NEW(values[count]); values[count].x := x; INC(count)
      END
    END
  END;
  IF count = 0 THEN Fail("no valid observations") END;
  base := 0;
  WHILE base < count DO
    batch := workers;
    IF batch > count-base THEN batch := count-base END;
    FOR slot := 0 TO batch-1 DO
      IF Pipe(slot) = 0 THEN Fail("cannot create worker pipe") END;
      pid := Fork(slot);
      IF pid < 0 THEN Fail("cannot fork worker") END;
      IF pid = 0 THEN Send(slot, J0(values[base+slot].x)) END;
      values[base+slot].pid := pid
    END;
    FOR slot := 0 TO batch-1 DO
      IF Collect(slot, values[base+slot].y) = 0 THEN Fail("numeric worker failed") END
    END;
    INC(base, batch)
  END;
  IF OpenOutput(target) = 0 THEN Fail("cannot open output") END;
  FOR i := 0 TO count-1 DO
    IF Row(values[i].x, values[i].y, values[i].pid) = 0 THEN Fail("output write failed") END
  END;
  IF CloseOutput() = 0 THEN Fail("output close failed") END;
  Cleanup;
  Message("Wrote observations to:", 0); Message(target, 0)
END Bessel.
