! Bessel Observatory: validate input, evaluate the common midpoint integral in child processes, then save CSV.
! The parent owns file I/O and result ordering; children perform the numerical work.
! The common CLI accepts an input file or -, an output filename, and a worker limit from 1 to 16.
! Fortran 2008, POSIX LP64: modules, kinds, IEEE checks, ISO_C_BINDING, IOSTAT.
module observatory
  use iso_c_binding
  use iso_fortran_env, only: error_unit, input_unit, real64
  use, intrinsic :: ieee_arithmetic
  implicit none
  ! Declare exact C ABI contracts so addresses and descriptor integers cross the language boundary correctly.
  interface
    ! Bind a pipe creation call using C-compatible descriptor storage.
    ! Inputs: A two-element C integer array to receive descriptors.
    ! Outputs: The descriptor pair and an OS return code.
    ! Used by: The main program before launching a child.
    function c_pipe(fds) bind(C, name='pipe') result(rc)
      import c_int
      integer(c_int) :: fds(2), rc
    end function
    ! Bind creation of a separate OS process.
    ! Inputs: No explicit arguments; the process state is duplicated.
    ! Outputs: Zero in the child, child PID in the parent, or a negative error.
    ! Used by: The main batching loop to start numerical workers.
    function c_fork() bind(C, name='fork') result(pid)
      import c_int
      integer(c_int) :: pid
    end function
    ! Bind release of an owned pipe endpoint.
    ! Inputs: A descriptor passed by value.
    ! Outputs: An OS return code.
    ! Used by: Both parent and child process branches during cleanup.
    function c_close(fd) bind(C, name='close') result(rc)
      import c_int
      integer(c_int), value :: fd
      integer(c_int) :: rc
    end function
    ! Bind reading into referenced Fortran storage through a C pointer.
    ! Inputs: A descriptor, destination address and byte count.
    ! Outputs: The count of bytes transferred or an OS error.
    ! Used by: The parent when receiving a numerical worker result.
    function c_read(fd, buf, n) bind(C, name='read') result(rc)
      import c_int, c_ptr, c_size_t, c_long
      integer(c_int), value :: fd
      type(c_ptr), value :: buf
      integer(c_size_t), value :: n
      integer(c_long) :: rc
    end function
    ! Bind sending referenced Fortran storage through a C pointer.
    ! Inputs: A descriptor, source address and byte count.
    ! Outputs: The count of bytes transferred or an OS error.
    ! Used by: The child after calculating its result.
    function c_write(fd, buf, n) bind(C, name='write') result(rc)
      import c_int, c_ptr, c_size_t, c_long
      integer(c_int), value :: fd
      type(c_ptr), value :: buf
      integer(c_size_t), value :: n
      integer(c_long) :: rc
    end function
    ! Bind waiting for a specific child and its completion status.
    ! Inputs: A child PID, status output and wait options.
    ! Outputs: The waited PID/status or an error return.
    ! Used by: The parent to reap and validate its numerical workers.
    function c_wait(pid, status, options) bind(C, name='waitpid') result(rc)
      import c_int
      integer(c_int), value :: pid, options
      integer(c_int) :: status, rc
    end function
    ! Bind immediate process termination for child completion and fatal errors.
    ! Inputs: An exit code.
    ! Outputs: No return; the process exits.
    ! Used by: fail and the child-only compute/send path.
    subroutine c_exit(code) bind(C, name='_exit')
      import c_int
      integer(c_int), value :: code
    end subroutine
  end interface
contains
  ! Report a fatal problem without a compiler-specific error-stop backtrace.
  ! Inputs: A diagnostic message.
  ! Outputs: A stderr line followed by process status 1.
  ! Used by: Argument, I/O, input-size and worker checks in the main program.
  subroutine fail(message)
    character(*), intent(in) :: message
    write(error_unit, '(a)') 'error: '//message
    call c_exit(1_c_int)
  end subroutine
  ! Generate midpoint samples and sum them through typed pointer sections.
  ! Inputs: One bounded real x.
  ! Outputs: The approximate J0 result; temporary sample storage is released on return.
  ! Used by: The child branch in the main program.
  function j0(x) result(y)
    real(real64), intent(in) :: x
    real(real64) :: y
    real(c_double), allocatable, target :: samples(:)
    real(c_double), pointer :: view(:), tail(:)
    integer :: k
    allocate(samples(16384))
    do k = 0, 16383
      samples(k + 1) = cos(x * sin(acos(-1.0_real64) * (k + 0.5_real64) / 16384))
    end do
    ! Interoperate with a C pointer, then use native typed pointer sections.
    ! Fortran expresses strides/subviews through array descriptors rather
    ! than portable raw address addition. TARGET stays alive throughout.
    call c_f_pointer(c_loc(samples), view, [size(samples)])
    y = 0
    do k = 1, size(view), 2
      tail => view(k:k+1)
      y = y + sum(tail)
    end do
    y = y / 16384
  end function
end module

! Use the module services to coordinate input, worker processes and final output.
program bessel
  use observatory
  implicit none
  real(c_double), target :: xs(4096), ys(4096)
  integer(c_int) :: pids(4096), readers(16), fds(2), pid, status, rc
  integer(c_long) :: transferred
  integer :: jobs, count, unit, output, ios, i, j, k, n, started
  character(4096) :: source, target, line, text, message
  character(128) :: arg
  logical :: good
  source = '-'; target = 'results.csv'; jobs = 2; count = 0
  if (command_argument_count() >= 1) call get_command_argument(1, source)
  if (trim(source) == '--help') then
    print '(a)', 'Usage: bessel-fortran [INPUT|- [OUTPUT [WORKERS 1..16]]]'
    stop
  end if
  if (command_argument_count() > 3) call fail('too many arguments')
  if (command_argument_count() >= 2) call get_command_argument(2, target)
  if (command_argument_count() >= 3) then
    call get_command_argument(3, arg)
    if (verify(trim(arg), '0123456789') /= 0 .or. len_trim(arg) == 0) call fail('invalid workers')
    read(arg, *, iostat=ios) jobs
    if (ios /= 0) call fail('invalid workers')
  end if
  if (jobs < 1 .or. jobs > 16) call fail('workers must be 1..16')
  unit = input_unit
  if (trim(source) /= '-') then
    open(newunit=unit, file=trim(source), status='old', action='read', iostat=ios, iomsg=message)
    if (ios /= 0) call fail(trim(message))
  else
    write(error_unit, '(a)') 'Enter one x per line; blank line or EOF finishes:'
  end if
  do
    ! Read a full text record and distinguish EOF from an actual read failure.
    read(unit, '(a)', iostat=ios, iomsg=message) line
    if (ios < 0) exit
    if (ios > 0) call fail(trim(message))
    text = trim(adjustl(line))
    if (len_trim(text) == 0) exit
    if (text(1:1) == '#') cycle
    ! Disallow list-directed separators/repetition and trailing tokens.
    if (verify(trim(text), '0123456789+-.eE') /= 0) then
      write(error_unit, '(a)') 'warning: invalid number; skipped'
      cycle
    end if
    block
      real(real64) :: x
      ! Attempt numeric conversion without allowing an invalid token to abort the runtime.
      read(text, *, iostat=ios) x
      if (ios == 0) then
        if (.not. ieee_is_finite(x)) ios = 1
        if (abs(x) > 1000) ios = 1
      end if
      if (ios /= 0) then
        write(error_unit, '(a)') 'warning: invalid number; skipped'
        cycle
      end if
      if (count == 4096) call fail('at most 4096 values')
      count = count + 1; xs(count) = x
    end block
  end do
  if (unit /= input_unit) close(unit)
  if (count == 0) call fail('no valid input values')
  ! Process bounded groups so worker count means simultaneous OS processes.
  do i = 1, count, jobs
    n = min(jobs, count - i + 1); started = 0; good = .true.
    do j = 1, n
      k = i + j - 1
      rc = c_pipe(fds)
      if (rc /= 0) then
        good = .false.; exit
      end if
      pid = c_fork()
      ! Calculate and send the result only in the child, then terminate that child.
      if (pid == 0) then
        rc = c_close(fds(1)); ys(k) = j0(xs(k))
        transferred = c_write(fds(2), c_loc(ys(k)), c_sizeof(ys(k)))
        rc = c_close(fds(2))
        call c_exit(merge(0_c_int, 1_c_int, transferred == c_sizeof(ys(k))))
      end if
      rc = c_close(fds(2))
      if (pid < 0) then
        rc = c_close(fds(1)); good = .false.; exit
      end if
      pids(k) = pid; readers(j) = fds(1); started = started + 1
    end do
    ! Collect and reap every launched child, even if the batch stopped launching early.
    do j = 1, started
      k = i + j - 1
      transferred = c_read(readers(j), c_loc(ys(k)), c_sizeof(ys(k)))
      rc = c_close(readers(j)); rc = c_wait(pids(k), status, 0_c_int)
      good = good .and. transferred == c_sizeof(ys(k)) .and. rc == pids(k) .and. status == 0
    end do
    if (.not. good) call fail('worker failed')
  end do
  ! Create the result file after all computations have succeeded.
  open(newunit=output, file=trim(target), status='replace', action='write', iostat=ios, iomsg=message)
  if (ios /= 0) call fail(trim(message))
  write(output, '(a)', iostat=ios) 'x,j0,worker_pid'
  if (ios /= 0) call fail('write failed')
  do i = 1, count
    ! Use explicit real and integer formatting to produce the shared CSV schema.
    write(output, '(es24.16e3,a,es24.16e3,a,i0)', iostat=ios) xs(i), ',', ys(i), ',', pids(i)
    if (ios /= 0) call fail('write failed')
  end do
  close(output, iostat=ios)
  if (ios /= 0) call fail('close failed')
  print '(a,i0,a)', 'Wrote ', count, ' observations'
end program
