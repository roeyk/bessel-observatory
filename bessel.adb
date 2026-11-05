-- Bessel Observatory: validate input, evaluate the common midpoint integral in child processes, then save CSV.
-- The parent owns file I/O and result ordering; children perform the numerical work.
-- The common CLI accepts an input file or -, an output filename, and a worker limit from 1 to 16.
with Ada.Command_Line;
with Ada.Exceptions;
with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Numerics.Long_Elementary_Functions;
with Interfaces.C;
with System;
with System.Storage_Elements;

procedure Bessel is
   -- Ada 2012, POSIX LP64. C imports expose OS processes, not Ada tasks.
   use Ada.Text_IO, Ada.Command_Line;
   use Ada.Numerics.Long_Elementary_Functions;
   use type Interfaces.C.int;
   use type Interfaces.C.long;
   use type Interfaces.C.size_t;
   use System.Storage_Elements;
   subtype C_Int is Interfaces.C.int;
   subtype C_Long is Interfaces.C.long;
   type Pipe_Pair is array (0 .. 1) of C_Int with Convention => C;
   -- Bind the OS operation that creates a one-way communication channel.
   -- Inputs: An output array with two descriptor slots.
   -- Outputs: A C status code and reading/writing descriptors.
   -- Used by: Batch before forking a worker.
   function Pipe (Fds : out Pipe_Pair) return C_Int with Import, Convention => C, External_Name => "pipe";
   -- Bind the OS operation that duplicates the current process.
   -- Inputs: No explicit arguments; the current process state is copied.
   -- Outputs: Zero in the child, the child PID in the parent, or a negative error.
   -- Used by: Batch to create genuinely separate numerical workers.
   function Fork return C_Int with Import, Convention => C, External_Name => "fork";
   -- Bind descriptor closure for owned pipe endpoints.
   -- Inputs: One C file descriptor.
   -- Outputs: A C success/failure status.
   -- Used by: Batch while transferring endpoint ownership and cleaning up.
   function Close (Fd : C_Int) return C_Int with Import, Convention => C, External_Name => "close";
   -- Bind reading from an OS descriptor into borrowed storage.
   -- Inputs: A descriptor, destination address and maximum byte count.
   -- Outputs: The number of bytes received, zero for EOF, or a negative error.
   -- Used by: Transfer to assemble a complete worker result.
   function Read (Fd : C_Int; Buf : System.Address; N : Interfaces.C.size_t) return C_Long
     with Import, Convention => C, External_Name => "read";
   -- Bind writing borrowed storage to an OS descriptor.
   -- Inputs: A descriptor, source address and requested byte count.
   -- Outputs: The number of bytes sent, or a negative error.
   -- Used by: Transfer in the child to deliver its numerical result.
   function Write (Fd : C_Int; Buf : System.Address; N : Interfaces.C.size_t) return C_Long
     with Import, Convention => C, External_Name => "write";
   -- Bind waiting for one specific child process.
   -- Inputs: A child PID, output status slot and wait options.
   -- Outputs: The waited PID/status, or a negative error.
   -- Used by: Batch to reap workers and reject unsuccessful child exits.
   function Waitpid (Pid : C_Int; Status : out C_Int; Options : C_Int) return C_Int
     with Import, Convention => C, External_Name => "waitpid";
   -- Bind immediate child termination without returning to the parent workflow.
   -- Inputs: The desired child exit code.
   -- Outputs: No return; the child process terminates.
   -- Used by: Batch after a child sends its result or detects a transfer failure.
   procedure Child_Exit (Code : C_Int) with Import, Convention => C, External_Name => "_exit", No_Return;
   -- Instantiate type-specific formatting for Long_Float values in the final CSV.
   package Real_IO is new Float_IO (Long_Float);
   type Observation is record
      X, Y : Long_Float;
      Pid : C_Int;
   end record;
   type Table is array (Positive range <>) of Observation;
   Rows : Table (1 .. 4096);
   Count : Natural := 0;
   Jobs : Positive := 2;
   Input_File, Output_File : File_Type;

   -- Parse an Ada numeric value and enforce the shared observation range.
   -- Inputs: A candidate input string.
   -- Outputs: A finite Long_Float in range, or Constraint_Error.
   -- Used by: Read_Values for per-line validation.
   function Number (S : String) return Long_Float is
      X : constant Long_Float := Long_Float'Value (S);
   begin
      if not (X >= -1000.0 and X <= 1000.0) then
         raise Constraint_Error with "expected finite x in [-1000,1000]";
      end if;
      return X;
   end Number;
   -- Approximate the Bessel integral with uniformly spaced midpoint samples.
   -- Inputs: One validated Long_Float X.
   -- Outputs: The approximate J0 value.
   -- Used by: Batch in each child process.
   function J0 (X : Long_Float) return Long_Float is
      Sum : Long_Float := 0.0;
   begin
      for K in 0 .. 16383 loop
         Sum := Sum + Cos (X * Sin (Ada.Numerics.Pi * (Long_Float (K) + 0.5) / 16384.0));
      end loop;
      return Sum / 16384.0;
   end J0;
   -- Complete a pipe transfer while advancing within a referenced scalar.
   -- Inputs: A descriptor, an in-out Long_Float, and a direction flag.
   -- Outputs: True if every byte moved; False on EOF or an I/O error.
   -- Used by: Batch in the child writer and parent reader.
   function Transfer (Fd : C_Int; Value : in out Long_Float; Writing : Boolean) return Boolean is
      Bytes : constant Natural := Long_Float'Size / System.Storage_Unit;
      Offset : Natural := 0;
      N : C_Long;
   begin
      -- Value is a borrowed reference. Address + Storage_Offset is BYTE
      -- arithmetic; all addresses stay inside this live scalar's storage.
      while Offset < Bytes loop
         if Writing then
            N := Write (Fd, Value'Address + Storage_Offset (Offset), Interfaces.C.size_t (Bytes - Offset));
         else
            N := Read (Fd, Value'Address + Storage_Offset (Offset), Interfaces.C.size_t (Bytes - Offset));
         end if;
         if N <= 0 then return False; end if;
         Offset := Offset + Natural (N);
      end loop;
      return True;
   end Transfer;
   -- Collect valid observations using the currently selected Ada input stream.
   -- Inputs: Current input plus the enclosing Rows and Count storage.
   -- Outputs: Rows/Count filled in input order; recoverable bad lines are skipped.
   -- Used by: The main procedure before starting process batches.
   procedure Read_Values is
   begin
      while not End_Of_File loop
         declare
            S : constant String := Ada.Strings.Fixed.Trim (Get_Line, Ada.Strings.Both);
            X : Long_Float;
         begin
            exit when S'Length = 0;
            if S (S'First) /= '#' then
               begin
                  X := Number (S);
                  if Count = Rows'Length then raise Program_Error with "at most 4096 values"; end if;
                  Count := Count + 1; Rows (Count).X := X;
               exception
                  when Constraint_Error => Put_Line (Standard_Error, "warning: invalid number; skipped");
               end;
            end if;
         end;
      end loop;
   end Read_Values;
   -- Run the specified slice of observations in separate child processes.
   -- Inputs: First and Last indexes into the enclosing Rows array.
   -- Outputs: Result values/PIDs stored in Rows; failure raises after started children are collected.
   -- Used by: The main procedure once per worker-sized slice.
   procedure Batch (First, Last : Positive) is
      Pids, Readers : array (First .. Last) of C_Int;
      Fds : Pipe_Pair;
      Started : Natural := 0;
      Pid, Ignored, Status : C_Int;
      Transferred : Boolean;
      Good : Boolean := True;
   begin
      for I in First .. Last loop
         -- Stop launching new workers if an OS resource cannot be acquired.
         if Pipe (Fds) /= 0 then Good := False; exit; end if;
         Pid := Fork;
         -- Select the child-only path: compute, transmit and terminate.
         if Pid = 0 then
            Ignored := Close (Fds (0));
            Rows (I).Y := J0 (Rows (I).X);
            Transferred := Transfer (Fds (1), Rows (I).Y, True);
            Ignored := Close (Fds (1));
            if Transferred then Child_Exit (0); else Child_Exit (1); end if;
         end if;
         Ignored := Close (Fds (1));
         if Pid < 0 then Ignored := Close (Fds (0)); Good := False; exit; end if;
         Pids (I) := Pid; Readers (I) := Fds (0); Started := Started + 1;
      end loop;
      -- Collect only the processes actually launched, including a partially successful batch.
      for Offset in 1 .. Started loop
         declare I : constant Positive := First + Offset - 1; begin
            Transferred := Transfer (Readers (I), Rows (I).Y, False);
            Ignored := Close (Readers (I));
            Pid := Waitpid (Pids (I), Status, 0);
            Good := Good and Transferred and Pid = Pids (I) and Status = 0;
            Rows (I).Pid := Pids (I);
         end;
      end loop;
      if not Good then raise Program_Error with "worker failed"; end if;
   end Batch;
begin
   if Argument_Count = 1 and then Argument (1) = "--help" then
      Put_Line ("Usage: bessel-ada [INPUT|- [OUTPUT [WORKERS 1..16]]]"); return;
   end if;
   if Argument_Count > 3 then raise Constraint_Error with "too many arguments"; end if;
   if Argument_Count >= 3 then Jobs := Positive'Value (Argument (3)); end if;
   if Jobs > 16 then raise Constraint_Error with "workers must be 1..16"; end if;
   if Argument_Count >= 1 and then Argument (1) /= "-" then
      Open (Input_File, In_File, Argument (1)); Set_Input (Input_File);
   else Put_Line (Standard_Error, "Enter one x per line; blank line or EOF finishes:"); end if;
   Read_Values;
   -- Restore the standard stream before closing the file that had replaced it.
   Set_Input (Standard_Input);
   if Is_Open (Input_File) then Close (Input_File); end if;
   if Count = 0 then raise Constraint_Error with "no valid input values"; end if;
   declare I : Positive := 1; begin
      while I <= Count loop Batch (I, Natural'Min (I + Jobs - 1, Count)); I := I + Jobs; end loop;
   end;
   -- Create output only after all observation batches have succeeded.
   Create (Output_File, Out_File, (if Argument_Count >= 2 then Argument (2) else "results.csv"));
   Put_Line (Output_File, "x,j0,worker_pid");
   for I in 1 .. Count loop
      Real_IO.Put (Output_File, Rows (I).X, Fore => 1, Aft => 16, Exp => 3); Put (Output_File, ',');
      Real_IO.Put (Output_File, Rows (I).Y, Fore => 1, Aft => 16, Exp => 3); Put (Output_File, ',');
      Put_Line (Output_File, C_Int'Image (Rows (I).Pid));
   end loop;
   Close (Output_File); Put_Line ("Wrote" & Natural'Image (Count) & " observations");
exception
   -- Close remaining file resources and turn fatal exceptions into a readable failed run.
   when E : others =>
      Set_Input (Standard_Input);
      if Is_Open (Input_File) then Close (Input_File); end if;
      if Is_Open (Output_File) then Close (Output_File); end if;
      Put_Line (Standard_Error, "error: " & Ada.Exceptions.Exception_Message (E)); Set_Exit_Status (Failure);
end Bessel;
