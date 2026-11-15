' Bessel Observatory — modern Visual Basic .NET console edition.
' Build: dotnet build bessel.vbproj -c Release
' Run: dotnet build/visual-basic/bessel-visual-basic.dll [INPUT|- [OUTPUT [WORKERS]]]
' The project uses a portable DLL, launched by dotnet on Linux, macOS or Windows.
' Numerical work and orchestration are VB; Tasks only transport child-process I/O.
Option Strict On
Option Explicit On
Option Infer On

Imports System
Imports System.Collections.Generic
Imports System.Diagnostics
Imports System.Globalization
Imports System.IO
Imports System.Reflection
Imports System.Text
Imports System.Text.RegularExpressions
Imports System.Threading.Tasks

Module BesselObservatory
    Private Const Samples As Integer = 16384
    Private Const MaximumValues As Integer = 4096
    Private ReadOnly Invariant As CultureInfo = CultureInfo.InvariantCulture
    Private ReadOnly DecimalToken As New Regex(
        "\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z",
        RegexOptions.CultureInvariant Or RegexOptions.NonBacktracking)

    ' Validate a decimal observation without throwing on ordinary malformed input.
    ' Input: normalized text. Output: Boolean success and a ByRef Double value.
    ' Callers: ReadValues and WorkerMain enforce the shared finite input domain.
    Private Function TryNumber(text As String, ByRef value As Double) As Boolean
        Return DecimalToken.IsMatch(text) AndAlso
            Double.TryParse(text, NumberStyles.Float, Invariant, value) AndAlso
            Double.IsFinite(value) AndAlso Math.Abs(value) <= 1000.0
    End Function

    ' Collect valid observations, retaining order and reporting recoverable errors.
    ' Input: borrowed reader. Output: 1–4096 values, or an input/I/O exception.
    ' Caller: Main owns the reader and selects file or interactive input.
    Private Function ReadValues(reader As TextReader) As List(Of Double)
        Dim values As New List(Of Double)()
        Dim lineNumber As Integer = 0
        Do
            Dim line = reader.ReadLine()
            If line Is Nothing Then Exit Do
            lineNumber += 1
            Dim text = line.Trim()
            If text.Length = 0 Then Exit Do
            If text.StartsWith("#", StringComparison.Ordinal) Then Continue Do
            Dim value As Double
            If TryNumber(text, value) Then
                If values.Count = MaximumValues Then
                    Throw New ArgumentException("at most 4096 values are allowed")
                End If
                values.Add(value)
            Else
                Console.Error.WriteLine($"warning: line {lineNumber}: invalid value; skipped")
            End If
        Loop
        If values.Count = 0 Then Throw New ArgumentException("no valid input values")
        Return values
    End Function

    ' Approximate J0 using midpoint quadrature and compensated summation.
    ' Input: validated x. Output: a Double approximation. Caller: WorkerMain only.
    Private Function Observe(x As Double) As Double
        ' VB array declarations use an inclusive upper bound: exactly Samples cells.
        ' The managed array remains reachable throughout both loops; indexing is
        ' bounds checked. VB has no native raw-pointer arithmetic syntax.
        Dim terms(Samples - 1) As Double
        For index As Integer = 0 To terms.Length - 1
            terms(index) = Math.Cos(x * Math.Sin(Math.PI * (index + 0.5) / Samples))
        Next
        Dim total As Double = 0.0
        Dim correction As Double = 0.0
        For Each term In terms
            Dim adjusted = term - correction
            Dim updated = total + adjusted
            correction = (updated - total) - adjusted
            total = updated
        Next
        Return total / Samples
    End Function

    ' Execute a child partition and return CSV records through stdout.
    ' Input: decimal lines on stdin. Output: x,j0,real OS PID rows or an exception.
    ' Caller: Main's private --worker mode; no recursive process creation occurs.
    Private Sub WorkerMain()
        Dim count As Integer = 0
        Do
            Dim line = Console.ReadLine()
            If line Is Nothing Then Exit Do
            Dim value As Double
            If Not TryNumber(line, value) OrElse count = MaximumValues Then
                Throw New InvalidDataException("invalid worker input")
            End If
            count += 1
            Console.WriteLine(String.Join(",", value.ToString("R", Invariant),
                                          Observe(value).ToString("R", Invariant),
                                          Environment.ProcessId.ToString(Invariant)))
        Loop
        If count = 0 Then Throw New InvalidDataException("empty worker partition")
    End Sub

    ' Feed a partition without blocking the parent while the child emits results.
    ' Inputs: owned pipe writer and complete input. Output: task completing after EOF.
    ' Caller: StartWorker. Using closes stdin even if a write fails.
    Private Async Function SendInputAsync(writer As StreamWriter, text As String) As Task
        Using writer
            Await writer.WriteAsync(text).ConfigureAwait(False)
        End Using
    End Function

    ' Hold references to one OS process and its concurrent pipe operations.
    ' Main's scheduler owns these objects; Dispose releases process/pipe resources.
    Private NotInheritable Class WorkerJob
        Implements IDisposable

        Public ReadOnly Child As Process
        Public ReadOnly First As Integer
        Public ReadOnly Count As Integer
        Public Input As Task
        Public Output As Task(Of String)
        Public Errors As Task(Of String)

        ' Retain the process and the partition's bounds; no process is started here.
        ' Inputs: unstarted process, first index, count. Output: owned job.
        ' Caller: StartWorker before starting the child and acquiring its streams.
        Public Sub New(childProcess As Process, firstIndex As Integer, itemCount As Integer)
            Child = childProcess
            First = firstIndex
            Count = itemCount
        End Sub

        ' Stop unfinished work, reap the child, observe pipe tasks and release handles.
        ' Input: this owned job. Output: released resources, with cleanup diagnostics.
        ' Callers: StartWorker on startup failure; RunWorkers in its Finally block.
        Public Sub Dispose() Implements IDisposable.Dispose
            Try
                If Not Child.HasExited Then Child.Kill(entireProcessTree:=True)
                Child.WaitForExit()
            Catch ex As InvalidOperationException
                ' A failed Process.Start has no process handle to reap.
            Catch ex As System.ComponentModel.Win32Exception
                Console.Error.WriteLine($"warning: worker cleanup: {ex.Message}")
            Finally
                Child.Dispose()
            End Try
            ' Killing a child closes its pipes. Observe all tasks, including failed
            ' writes, so no asynchronous pipe failure escapes the ownership scope.
            For Each pending In New Task() {Input, Output, Errors}
                If pending Is Nothing Then Continue For
                Try
                    pending.GetAwaiter().GetResult()
                Catch ex As IOException
                    ' RunWorkers reports normal pipe errors; cleanup preserves them.
                Catch ex As ObjectDisposedException
                    ' Startup failure may dispose streams before I/O completes.
                End Try
            Next
        End Sub
    End Class

    ' Launch the same portable assembly as a real child using argument-list escaping.
    ' Inputs: values and contiguous partition bounds. Output: owned live WorkerJob.
    ' Caller: RunWorkers starts at most the requested number of children.
    Private Function StartWorker(values As List(Of Double), first As Integer,
                                 count As Integer) As WorkerJob
        ' UseAppHost=false means Environment.ProcessPath is the current dotnet host.
        ' Assembly.Location is absolute, so launches also work from another directory.
        Dim start As New ProcessStartInfo With {
            .FileName = Environment.ProcessPath,
            .UseShellExecute = False,
            .RedirectStandardInput = True,
            .RedirectStandardOutput = True,
            .RedirectStandardError = True,
            .StandardInputEncoding = New UTF8Encoding(False),
            .StandardOutputEncoding = Encoding.UTF8,
            .StandardErrorEncoding = Encoding.UTF8
        }
        start.ArgumentList.Add(Assembly.GetExecutingAssembly().Location)
        start.ArgumentList.Add("--worker")
        Dim text As New StringBuilder()
        For index As Integer = first To first + count - 1
            text.AppendLine(values(index).ToString("R", Invariant))
        Next
        Dim job As New WorkerJob(New Process With {.StartInfo = start}, first, count)
        Try
            If Not job.Child.Start() Then Throw New IOException("worker did not start")
            ' Drain both output pipes before feeding stdin or waiting for exit.
            ' These Tasks move bytes; Observe runs only in the separate OS process.
            job.Output = job.Child.StandardOutput.ReadToEndAsync()
            job.Errors = job.Child.StandardError.ReadToEndAsync()
            job.Input = SendInputAsync(job.Child.StandardInput, text.ToString())
            Return job
        Catch
            job.Dispose()
            Throw
        End Try
    End Function

    ' Validate a child partition and place its records into the ordered result array.
    ' Inputs: finished job, original values, borrowed result array. Output: filled slice.
    ' Caller: RunWorkers, after checking successful child exit and all pipe operations.
    Private Sub CollectRows(job As WorkerJob, values As List(Of Double), rows As String())
        Using reader As New StringReader(job.Output.GetAwaiter().GetResult())
            For offset As Integer = 0 To job.Count - 1
                Dim line = reader.ReadLine()
                If line Is Nothing Then Throw New InvalidDataException("missing worker result")
                Dim fields = line.Split(","c)
                Dim x As Double
                Dim j0 As Double
                Dim pid As Integer
                If fields.Length <> 3 OrElse Not TryNumber(fields(0), x) OrElse
                    x <> values(job.First + offset) OrElse
                    Not Double.TryParse(fields(1), NumberStyles.Float, Invariant, j0) OrElse
                    Not Double.IsFinite(j0) OrElse Math.Abs(j0) > 1.0000000001 OrElse
                    Not Integer.TryParse(fields(2), NumberStyles.None, Invariant, pid) OrElse
                    pid <> job.Child.Id Then
                    Throw New InvalidDataException("invalid worker result or PID")
                End If
                rows(job.First + offset) = line
            Next
            If reader.ReadLine() IsNot Nothing Then
                Throw New InvalidDataException("excess worker results")
            End If
        End Using
    End Sub

    ' Partition work into a bounded number of real children and preserve result order.
    ' Inputs: accepted values, worker limit. Output: all CSV data rows or an exception.
    ' Caller: Main; output files remain unopened until this function succeeds.
    Private Function RunWorkers(values As List(Of Double), workerLimit As Integer) As String()
        Dim jobs As New List(Of WorkerJob)()
        Dim rows(values.Count - 1) As String
        Dim count = Math.Min(workerLimit, values.Count)
        Try
            For index As Integer = 0 To count - 1
                Dim first = index * values.Count \ count
                Dim last = (index + 1) * values.Count \ count
                jobs.Add(StartWorker(values, first, last - first))
            Next
            For Each job In jobs
                If Not job.Child.WaitForExit(60000) Then
                    Throw New TimeoutException("worker exceeded the 60-second wait limit")
                End If
                Dim errors = job.Errors.GetAwaiter().GetResult().Trim()
                If job.Child.ExitCode <> 0 Then
                    Throw New IOException($"worker {job.Child.Id} failed: {errors}")
                End If
                job.Input.GetAwaiter().GetResult()
                CollectRows(job, values, rows)
            Next
            Return rows
        Finally
            For Each job In jobs
                job.Dispose()
            Next
        End Try
    End Function

    ' Coordinate argument parsing, input, child calculations, CSV output and diagnostics.
    ' Inputs: CLI arguments and optional stdin. Output: exit status, CSV and messages.
    ' Caller: the .NET host; --worker is an internal mode used by StartWorker.
    Public Function Main(args As String()) As Integer
        Try
            If args.Length = 1 AndAlso args(0) = "--worker" Then
                WorkerMain()
                Return 0
            End If
            If args.Length = 1 AndAlso args(0) = "--help" Then
                Console.WriteLine("Usage: dotnet bessel-visual-basic.dll [INPUT|- [OUTPUT [WORKERS]]]")
                Console.WriteLine("Defaults: stdin, results.csv, 2 workers (range 1–16).")
                Return 0
            End If
            If args.Length > 3 Then Throw New ArgumentException("too many arguments; use --help")
            Dim source = If(args.Length > 0, args(0), "-")
            Dim target = If(args.Length > 1, args(1), "results.csv")
            Dim workers As Integer = 2
            If args.Length > 2 AndAlso
                (Not Integer.TryParse(args(2), NumberStyles.None, Invariant, workers) OrElse
                 workers < 1 OrElse workers > 16) Then
                Throw New ArgumentException("workers must be an integer from 1 through 16")
            End If
            Dim values As List(Of Double)
            If source = "-" Then
                Console.Error.WriteLine("Enter one x per line; blank line or EOF finishes:")
                values = ReadValues(Console.In)
            Else
                Using reader As New StreamReader(source, New UTF8Encoding(False, True))
                    values = ReadValues(reader)
                End Using
            End If
            Dim rows = RunWorkers(values, workers)
            ' Using flushes/disposes the file even on exceptions; flush failures reach
            ' the outer handler. Existing output is untouched by input/worker errors.
            Using writer As New StreamWriter(target, False, New UTF8Encoding(False))
                writer.WriteLine("x,j0,worker_pid")
                For Each row In rows
                    writer.WriteLine(row)
                Next
            End Using
            Console.WriteLine($"Wrote {rows.Length} observations to {target}")
            Return 0
        Catch ex As Exception
            ' Convert ordinary CLI, I/O and process exceptions at the application boundary.
            Console.Error.WriteLine($"error: {ex.Message}")
            Return 1
        End Try
    End Function
End Module
