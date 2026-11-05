**free
// Bessel Observatory for IBM i 7.5, fully free ILE RPG with embedded Db2 SQL.
// Compile and queue setup are in rpg_setup.txt. This edition uses native CALL
// parameters, DSPLY input, IFS files, and separate SBMJOB batch jobs.
// RPG has no block-comment delimiter; consecutive // lines are its convention.
ctl-opt dftactgrp(*no) actgrp(*new) bnddir('QC2LE') option(*srcstmt);

// Program entry: optional 32-character CL parameters select input/output/jobs.
// Inputs: input path or '-', output path, worker count; '*WORKER' is internal.
// Outputs: IFS CSV or an escape message. Called by a user or submitted batch job.
dcl-pi *n;
  argInput char(32) const options(*nopass);
  argOutput char(32) const options(*nopass);
  argWorkers char(32) const options(*nopass);
end-pi;

// Call the ILE C trigonometric functions by value.
// Input: angle in radians. Output: double result. Used by Observe's quadrature.
dcl-pr Cosine float(8) extproc('cos'); angle float(8) value; end-pr;
dcl-pr Sine float(8) extproc('sin'); angle float(8) value; end-pr;
// Obtain an OS process identifier for the worker CSV column.
// Input: none. Output: PID. Used by the '*WORKER' entry path.
dcl-pr GetPid int(10) extproc('getpid'); end-pr;
// Pause polling without consuming a CPU continuously.
// Input: seconds. Output: remaining seconds. Used by the parent's wait loop.
dcl-pr SleepSeconds uns(10) extproc('sleep'); seconds uns(10) value; end-pr;
// Execute one CL command through the IBM program-call ABI.
// Inputs: command bytes and packed length. Output: normal return or escape.
// Used by Command for SBMJOB and readable failure messages.
dcl-pr Execute extpgm('QCMDEXC');
  command char(32702) const options(*varsize);
  length packed(15:5) const;
end-pr;

dcl-s source varchar(32) inz('-');
dcl-s target varchar(32) inz('results.csv');
dcl-s runId char(32);
dcl-s text varchar(4096);
dcl-s response char(52);
dcl-s row varchar(256);
dcl-s commandText varchar(1024);
dcl-s total int(10) inz(0);
dcl-s workers int(10) inz(2);
dcl-s first int(10);
dcl-s last int(10);
dcl-s ordinal int(10);
dcl-s completed int(10);
dcl-s errors int(10);
dcl-s elapsed int(10);
dcl-s unused uns(10);
dcl-s pid int(10);
dcl-s x float(8);
dcl-s y float(8);
dcl-s worker ind inz(*off);
dcl-s failed ind inz(*off);
dcl-s stopInput ind inz(*off);

// Autocommit makes newly inserted work visible to independently submitted jobs.
exec sql set option commit=*none, closqlcsr=*endmod, naming=*sql;

// Capture ordinary RPG and CL exceptions, then report one application failure.
monitor;
  if %parms() > 3;
    Die('Expected at most three parameters');
  endif;
  if %parms() >= 1;
    source = %trim(argInput);
  endif;
  if source = '--help';
    dsply 'CALL BESSELAB/BESSEL (input output workers)';
    *inlr = *on;
    return;
  endif;
  worker = source = '*WORKER';
  if worker;
    if %parms() <> 3; Die('Worker requires run and ordinal'); endif;
    runId = argOutput;
    ordinal = %int(argWorkers);
    exec sql select x into :x from BESSELAB.WORK_ITEMS
      where run_id=:runId and ordinal=:ordinal and state='Q';
    CheckSql();
    y = Observe(x);
    pid = GetPid();
    exec sql update BESSELAB.WORK_ITEMS set y=:y, pid=:pid, state='D'
      where run_id=:runId and ordinal=:ordinal;
    CheckSql();
  else;
    if %parms() >= 2; target = %trim(argOutput); endif;
    if %parms() >= 3;
      text = %trim(argWorkers);
      if text = '' or %check('0123456789':text) <> 0;
        Die('Workers must be an integer from 1 to 16');
      endif;
      workers = %int(text);
    endif;
    if workers < 1 or workers > 16; Die('Workers must be 1..16'); endif;
    exec sql values hex(generate_unique()) into :runId;
    CheckSql();

    // DSPLY is the native workstation input path; blank input completes it.
    if source = '-';
      dou stopInput;
        clear response;
        dsply 'Enter x; blank finishes:' '' response;
        text = %trim(response);
        Accept();
      enddo;
    else;
      // IFS_READ performs CCSID conversion, preserving line order explicitly.
      exec sql declare inputRows cursor for
        select cast(line as varchar(4096))
        from table(QSYS2.IFS_READ(path_name=>:source,
          maximum_line_length=>4096, ignore_errors=>'NO'))
        order by line_number;
      exec sql open inputRows;
      CheckSql();
      dou stopInput;
        exec sql fetch inputRows into :text;
        if sqlcod = 100; leave; endif;
        CheckSql();
        Accept();
      enddo;
      exec sql close inputRows;
      CheckSql();
    endif;
    if total = 0; Die('No valid observations'); endif;

    // Submit at most workers jobs, then wait for that batch's database results.
    first = 1;
    dow first <= total;
      last = %min(total:first+workers-1);
      for ordinal = first to last;
        commandText = 'SBMJOB CMD(CALL PGM(BESSELAB/BESSEL) PARM(' +
          '''*WORKER'' ''' + %trim(runId) + ''' ''' +
          %trim(%char(ordinal)) + ''')) JOB(BESSEL) ' +
          'JOBQ(BESSELAB/BESSELQ)';
        Command(commandText);
      endfor;
      elapsed = 0;
      dou completed = last-first+1;
        exec sql select count(*) into :errors from BESSELAB.WORK_ITEMS
          where run_id=:runId and ordinal between :first and :last
          and state='E';
        CheckSql();
        if errors > 0; Die('A numeric batch job failed; inspect job log'); endif;
        exec sql select count(*) into :completed from BESSELAB.WORK_ITEMS
          where run_id=:runId and ordinal between :first and :last
          and state='D';
        CheckSql();
        if completed < last-first+1;
          if elapsed >= 600; Die('Batch timeout; inspect run in WORK_ITEMS'); endif;
          unused = SleepSeconds(1);
          elapsed += 1;
        endif;
      enddo;
      first = last+1;
      completed = 0;
    enddo;

    // Publish UTF-8 CSV only after every job has completed successfully.
    exec sql call QSYS2.IFS_WRITE_UTF8(path_name=>:target,
      line=>'x,j0,worker_pid', overwrite=>'REPLACE', end_of_line=>'LF');
    CheckSql();
    for ordinal = 1 to total;
      exec sql select x,y,pid into :x,:y,:pid from BESSELAB.WORK_ITEMS
        where run_id=:runId and ordinal=:ordinal;
      CheckSql();
      row = %trim(%char(x)) + ',' + %trim(%char(y)) + ',' + %trim(%char(pid));
      exec sql call QSYS2.IFS_WRITE_UTF8(path_name=>:target,
        line=>:row, overwrite=>'APPEND', end_of_line=>'LF');
      CheckSql();
    endfor;
    exec sql delete from BESSELAB.WORK_ITEMS where run_id=:runId;
    CheckSql();
    dsply 'Bessel observations written';
  endif;
on-error;
  failed = *on;
endmon;
if failed;
  if worker;
    exec sql update BESSELAB.WORK_ITEMS set state='E'
      where run_id=:runId and ordinal=:ordinal;
  endif;
  // Preserve failed run rows for diagnosis; queued jobs may still finish them.
  dsply ('Failed run: ' + %trim(runId));
  Die('Bessel failed; inspect the preceding job messages');
endif;
*inlr = *on;
return;

// Accept validates and records one observation in shared run storage.
// Inputs: global text and runId. Outputs: total, stopInput, or skipped warning.
// Used by: both input loops; SQL validates spelling before RPG converts it.
dcl-proc Accept;
  dcl-s valid int(10);
  dcl-s converted ind;
  text = %trim(text:x'050D152540'); // EBCDIC tab, CR, NL, LF, and space.
  if text = ''; stopInput = *on; return; endif;
  if %subst(text:1:1) = '#'; return; endif;
  exec sql values case when regexp_like(:text,
    '^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$')
    then 1 else 0 end into :valid;
  CheckSql();
  converted = *off;
  if valid = 1;
    monitor;
      x = %float(text);
      converted = x >= -1000 and x <= 1000;
    on-error;
      converted = *off;
    endmon;
  endif;
  if not converted; dsply 'Skipping invalid value'; return; endif;
  if total >= 4096; Die('At most 4096 observations are allowed'); endif;
  total += 1;
  exec sql insert into BESSELAB.WORK_ITEMS(run_id,ordinal,x,state)
    values(:runId,:total,:x,'Q');
  CheckSql();
end-proc;

// Observe performs double-precision midpoint quadrature in the worker job.
// Input: a validated x by value. Output: approximate J0(x).
// Used by: the '*WORKER' path. A based field aliases each array element;
// pointer arithmetic advances by its byte size, remaining inside the array.
dcl-proc Observe;
  dcl-pi *n float(8); value float(8) value; end-pi;
  dcl-c n 16384;
  dcl-c pi 3.14159265358979323846;
  dcl-s samples float(8) dim(n);
  dcl-s cursor pointer;
  dcl-s term float(8) based(cursor);
  dcl-s sum float(8) inz(0);
  dcl-s k int(10);
  for k = 1 to n;
    samples(k) = Cosine(value*Sine(pi*(k-0.5)/n));
  endfor;
  cursor = %addr(samples(1));
  for k = 1 to n;
    sum += term;
    if k < n; cursor += %size(term); endif;
  endfor;
  return sum/n;
end-proc;

// Command executes a CL operation through a varying-length string reference.
// Input: command text. Output: normal return or CL escape exception.
// Used by: Main to submit jobs and Die to propagate readable failures.
dcl-proc Command;
  dcl-pi *n; text varchar(32702) const; end-pi;
  Execute(text:%len(text));
end-proc;

// CheckSql turns failed SQL operations into an application exception.
// Input: the SQL precompiler's sqlcod. Output: normal return or escape.
// Used by: every SQL operation; FETCH handles end-of-data before calling it.
dcl-proc CheckSql;
  if sqlcod <> 0; Die('Database operation failed; inspect SQL job log'); endif;
end-proc;

// Die sends a CPF9898 escape message, preserving IBM i's error convention.
// Input: explanatory text. Output: job log message and exception to caller.
// Used by: validation, CheckSql, and the top-level error boundary.
dcl-proc Die;
  dcl-pi *n; message varchar(256) const; end-pi;
  Command('SNDPGMMSG MSGID(CPF9898) MSGF(QCPFMSG) MSGDTA(''' +
    %scanrpl('''':'''''' :message) + ''') MSGTYPE(*ESCAPE)');
end-proc;
