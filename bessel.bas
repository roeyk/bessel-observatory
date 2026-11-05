/'
  Bessel Observatory: validate input, evaluate the common midpoint integral in child processes, then save CSV.
  The parent owns file I/O and result ordering; children perform the numerical work.
  The common CLI accepts an input file or -, an output filename, and a worker limit from 1 to 16.
  FreeBASIC 1.10, Linux x86-64. Structured BASIC and explicit error checks.
  C ABI declarations are OS bindings only; the numerical work is BASIC.
'/
#include once "crt/stdlib.bi"
Extern "C"
    /'
      Expose the POSIX pipe operation through the C ABI.
      Inputs: A pointer to two Long descriptor slots.
      Outputs: An OS status plus a readable and writable endpoint.
      Used by: The main batch loop before each fork.
    '/
    Declare Function os_pipe Alias "pipe" (ByVal fds As Long Ptr) As Long
    /'
      Expose creation of an independent OS process.
      Inputs: The current process state; no explicit parameters.
      Outputs: Zero in the child, its PID in the parent, or a negative error.
      Used by: The main loop to distribute numerical work.
    '/
    Declare Function os_fork Alias "fork" () As Long
    /'
      Expose closure of a pipe endpoint.
      Inputs: One descriptor.
      Outputs: The OS return status.
      Used by: Parent and child paths when endpoint ownership ends.
    '/
    Declare Function os_close Alias "close" (ByVal fd As Long) As Long
    /'
      Expose reading a fixed-size result into BASIC-owned memory.
      Inputs: A descriptor, destination pointer and byte count.
      Outputs: The number of bytes read, or an error value.
      Used by: The parent when collecting one Double result.
    '/
    Declare Function os_read Alias "read" (ByVal fd As Long, ByVal buf As Any Ptr, ByVal n As ULongInt) As LongInt
    /'
      Expose sending a BASIC numeric value through a pipe.
      Inputs: A descriptor, source pointer and byte count.
      Outputs: The number of bytes written, or an error value.
      Used by: The child after computing J0.
    '/
    Declare Function os_write Alias "write" (ByVal fd As Long, ByVal buf As Any Ptr, ByVal n As ULongInt) As LongInt
    /'
      Expose waiting for a specific child and obtaining its exit status.
      Inputs: A PID, status pointer and options.
      Outputs: The waited PID and status, or an error value.
      Used by: The parent before accepting a worker result.
    '/
    Declare Function os_wait Alias "waitpid" (ByVal pid As Long, ByVal status As Long Ptr, ByVal flags As Long) As Long
    /'
      Terminate the child immediately without running parent cleanup paths.
      Inputs: An exit code.
      Outputs: No return value; the child exits.
      Used by: The child branch after attempting to send its Double result.
    '/
    Declare Sub os_exit Alias "_exit" (ByVal code As Long)
End Extern

/'
  End the run with a readable error message.
  Inputs: A descriptive String passed by reference.
  Outputs: A stderr diagnostic and process status 1.
  Used by: Argument, file, size-limit and worker checks throughout the main program.
'/
Sub Fail(ByRef message As String)
    Print #2, "error: " & message
    End 1
End Sub
/'
  Parse a complete C-style numeric token into a referenced BASIC Double.
  Inputs: The input String and an output Double reference.
  Outputs: True with a finite bounded value, or False for invalid input.
  Used by: The CLI worker-count check and main input loop.
'/
Function Number(ByRef text As String, ByRef x As Double) As Boolean
    Dim tail As ZString Ptr
    x = strtod(StrPtr(text), @tail)
    If tail = StrPtr(text) Then Return False
    If Len(Trim(*tail)) <> 0 Then Return False
    Return x = x AndAlso Abs(x) <= 1000
End Function
/'
  Calculate midpoint samples and sum them using a typed pointer cursor.
  Inputs: One validated Double x.
  Outputs: The approximate J0 result.
  Used by: Each child immediately after fork.
'/
Function J0(ByVal x As Double) As Double
    Dim total As Double = 0, pi As Double = 4 * Atn(1)
    Dim samples(0 To 16383) As Double
    For k As Integer = 0 To 16383
        samples(k) = Cos(x * Sin(pi * (k + 0.5) / 16384))
    Next
    Dim cursor As Double Ptr = @samples(0)
    ' Typed pointer addition advances by one Double; samples stays in scope.
    For k As Integer = 0 To 16383
        total += *cursor
        cursor += 1
    Next
    Return total / 16384
End Function

' Give diagnostics their own file channel so they do not mix with normal output.
Open Err For Output As #2
If Command(1) = "--help" Then
    Print "Usage: bessel-basic [INPUT|- [OUTPUT [WORKERS 1..16]]]"
    End 0
End If
If Len(Command(4)) Then Fail("too many arguments")
' Read positional arguments and fill in the shared defaults.
Dim source As String = Command(1), target As String = Command(2)
If source = "" Then source = "-"
If target = "" Then target = "results.csv"
Dim jobs As Integer = 2
If Len(Command(3)) Then
    Dim s As String = Command(3), j As Double
    If Not Number(s, j) Then Fail("invalid workers")
    If j <> Fix(j) OrElse j < 1 OrElse j > 16 Then Fail("workers must be 1..16")
    jobs = CInt(j)
End If
Dim inputFile As Integer = FreeFile
If source = "-" Then
    Print #2, "Enter one x per line; blank line or EOF finishes:"
    If Open Cons(For Input As #inputFile) Then Fail("cannot open stdin")
Else
    If Open(source For Input As #inputFile) Then Fail("cannot open input")
End If
Dim xs(0 To 4095) As Double, ys(0 To 4095) As Double
Dim pids(0 To 4095) As Long, readers(0 To 15) As Long
Dim count As Integer = 0
' Accept usable input lines in order; malformed lines do not prevent later input.
Do Until Eof(inputFile)
    Dim text As String, x As Double
    Line Input #inputFile, text
    text = Trim(text)
    If text = "" Then Exit Do
    If Left(text, 1) = "#" Then Continue Do
    If Not Number(text, x) Then
        Print #2, "warning: invalid number; skipped"
        Continue Do
    End If
    If count = 4096 Then Fail("at most 4096 values")
    xs(count) = x: count += 1
Loop
Close #inputFile
If count = 0 Then Fail("no valid input values")
' Limit simultaneous child workers by finishing one group before launching another.
For first As Integer = 0 To count - 1 Step jobs
    Dim n As Integer = jobs
    If first + n > count Then n = count - first
    Dim started As Integer = 0, good As Boolean = True
    For j As Integer = 0 To n - 1
        Dim fds(0 To 1) As Long
        If os_pipe(@fds(0)) <> 0 Then
            good = False: Exit For
        End If
        Dim pid As Long = os_fork()
        ' Compute in the child and send a binary Double back to the parent.
        If pid = 0 Then
            os_close(fds(0))
            Dim y As Double = J0(xs(first + j))
            Dim sent As LongInt = os_write(fds(1), @y, SizeOf(y))
            os_close(fds(1))
            If sent = SizeOf(y) Then os_exit(0) Else os_exit(1)
        End If
        os_close(fds(1))
        If pid < 0 Then
            os_close(fds(0)): good = False: Exit For
        End If
        pids(first + j) = pid: readers(j) = fds(0): started += 1
    Next
    ' Read and reap every successfully started worker, including partial-launch failures.
    For j As Integer = 0 To started - 1
        Dim k As Integer = first + j, status As Long
        Dim received As LongInt = os_read(readers(j), @ys(k), SizeOf(Double))
        os_close(readers(j))
        Dim waited As Long = os_wait(pids(k), @status, 0)
        If received <> SizeOf(Double) OrElse waited <> pids(k) OrElse status <> 0 Then good = False
    Next
    If Not good Then Fail("worker failed")
Next
' Open and write the CSV only after all workers have finished.
Dim outputFile As Integer = FreeFile
If Open(target For Output As #outputFile) Then Fail("cannot open output")
Print #outputFile, "x,j0,worker_pid"
For i As Integer = 0 To count - 1
    Print #outputFile, LTrim(Str(xs(i))) & "," & LTrim(Str(ys(i))) & "," & LTrim(Str(pids(i)))
    If Err Then Fail("write failed")
Next
Close #outputFile
If Err Then Fail("close failed")
Print "Wrote"; count; " observations to "; target
