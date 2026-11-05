(*
  Bessel Observatory: validate input, evaluate the common midpoint integral in child processes, then save CSV.
  The parent owns file I/O and result ordering; children perform the numerical work.
  The common CLI accepts an input file or -, an output filename, and a worker limit from 1 to 16.
*)
program Bessel;
{$mode objfpc}{$H+}
{ Free Pascal 3.2+: structured procedures, exceptions, TProcess ownership. }
uses SysUtils, Classes, Math, Process;
type
  TValues = array of Double;
  TProcesses = array of TProcess;
var
  // Keep decimal parsing and output stable even when the machine locale uses commas.
  FS: TFormatSettings;

(*
  Convert an observation token using the explicitly selected decimal separator.
  Inputs: The candidate numeric string S.
  Outputs: A bounded Double, or EConvertError for a bad observation.
  Used by: Run for ordinary input and internal worker arguments.
*)
function Number(const S: String): Double;
begin
  if not TryStrToFloat(Trim(S), Result, FS) then
    raise EConvertError.Create('expected a number');
  if IsNan(Result) or IsInfinite(Result) or (Abs(Result) > 1000) then
    raise EConvertError.Create('expected finite x in [-1000,1000]');
end;

(*
  Compute midpoint samples and sum them through a typed pointer.
  Inputs: One validated Double X.
  Outputs: The approximate J0 value.
  Used by: Run in the separate child process selected by --worker.
*)
function Observe(X: Double): Double;
var K: Integer; Sum: Double; Samples: array[0..16383] of Double; Cursor: PDouble;
begin
  Sum := 0;
  for K := 0 to 16383 do Samples[K] := Cos(X * Sin(Pi * (K + 0.5) / 16384));
  Cursor := @Samples[0];
  { Typed pointer arithmetic: Inc advances by SizeOf(Double), not one byte.
    Samples owns the storage for this entire procedure. }
  for K := 0 to High(Samples) do begin Sum := Sum + Cursor^; Inc(Cursor); end;
  Result := Sum / 16384;
end;

(*
  Implement help, child computation, and the full parent workflow.
  Inputs: ParamStr values and either a file stream or standard input.
  Outputs: CSV/console output; failures are raised to the program error handler.
  Used by: The final program block after it sets decimal formatting.
*)
procedure Run;
var
  Source, Target, S: String;
  InFile, OutFile: Text;
  Values: TValues;
  Rows: TStringList;
  Children: TProcesses;
  I, J, N, Jobs, Count: Integer;
  X: Double;
  Buffer: array[0..255] of Char;
begin
  if (ParamCount = 1) and (ParamStr(1) = '--help') then begin
    WriteLn('Usage: bessel-pascal [INPUT|- [OUTPUT [WORKERS 1..16]]]'); Exit;
  end;
  if (ParamCount = 2) and (ParamStr(1) = '--worker') then begin
    X := Number(ParamStr(2));
    WriteLn(FloatToStr(X, FS), ',', FloatToStr(Observe(X), FS), ',', GetProcessID); Exit;
  end;
  if ParamCount > 3 then raise Exception.Create('too many arguments');
  Source := '-'; Target := 'results.csv'; Jobs := 2;
  if ParamCount >= 1 then Source := ParamStr(1);
  if ParamCount >= 2 then Target := ParamStr(2);
  if ParamCount >= 3 then Jobs := StrToInt(ParamStr(3));
  if (Jobs < 1) or (Jobs > 16) then raise Exception.Create('workers must be 1..16');
  if Source = '-' then begin
    WriteLn(StdErr, 'Enter one x per line; blank line or EOF finishes:');
    AssignFile(InFile, '');
  end else AssignFile(InFile, Source);
  // Open the selected input before reading values; opening errors become exceptions.
  Reset(InFile);
  try
    // Normalize and classify lines, stopping at the first blank line or EOF.
    while not EOF(InFile) do begin
      ReadLn(InFile, S); S := Trim(S);
      if S = '' then Break;
      if S[1] = '#' then Continue;
      try
        X := Number(S);
        // Append only a successfully parsed value so later output preserves accepted input order.
        SetLength(Values, Length(Values) + 1); Values[High(Values)] := X;
      except on E: EConvertError do WriteLn(StdErr, 'warning: ', E.Message, '; skipped'); end;
      if Length(Values) > 4096 then raise Exception.Create('at most 4096 values');
    end;
  finally CloseFile(InFile); end;
  if Length(Values) = 0 then raise Exception.Create('no valid input values');
  // Keep result rows owned by a scoped object until they can be written together.
  Rows := TStringList.Create;
  try
    I := 0;
    while I < Length(Values) do begin
      N := Min(Jobs, Length(Values) - I); SetLength(Children, N);
      try
        for J := 0 to N - 1 do begin
          // Create one child per value without waiting, so the whole bounded batch can run concurrently.
          Children[J] := TProcess.Create(nil);
          Children[J].Executable := ExpandFileName(ParamStr(0));
          Children[J].Parameters.Add('--worker');
          Children[J].Parameters.Add(FloatToStr(Values[I + J], FS));
          Children[J].Options := [poUsePipes]; Children[J].Execute;
        end;
        for J := 0 to N - 1 do begin
          S := '';
          repeat
            // Drain all available child output rather than assuming one read contains the full row.
            Count := Children[J].Output.Read(Buffer, SizeOf(Buffer));
            if Count > 0 then S := S + Copy(Buffer, 0, Count);
          until Count = 0;
          // Check process completion before accepting its buffered CSV row.
          Children[J].WaitOnExit;
          if (Children[J].ExitStatus <> 0) or (Trim(S) = '') then raise Exception.Create('worker failed');
          Rows.Add(Trim(S));
        end;
      finally
        for J := 0 to N - 1 do
          if Assigned(Children[J]) then begin
            // Terminate and reap remaining workers when normal collection or an exception leaves this scope.
            if Children[J].Running then begin Children[J].Terminate(1); Children[J].WaitOnExit; end;
            FreeAndNil(Children[J]);
          end;
      end;
      Inc(I, N);
    end;
    // Create the output after the calculation phase, then close it even if writing fails.
    AssignFile(OutFile, Target); Rewrite(OutFile);
    try
      WriteLn(OutFile, 'x,j0,worker_pid');
      for I := 0 to Rows.Count - 1 do WriteLn(OutFile, Rows[I]);
    finally CloseFile(OutFile); end;
    WriteLn('Wrote ', Rows.Count, ' observations to ', Target);
  finally Rows.Free; end;
end;
begin
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
  try Run;
  except on E: Exception do begin WriteLn(StdErr, 'error: ', E.Message); Halt(1); end; end;
end.
