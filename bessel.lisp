#|
  Bessel Observatory: validate observations, compute J0 in separate OS workers, and save ordered CSV.
  The parent reads input and owns result ordering; the worker computes the midpoint approximation.
  An invalid observation is skipped with a warning, while failed I/O or workers abort the run.
|#
;;;; Common Lisp (SBCL 2.x): conditions, a recovery restart, LOOP, resource macros.
(require :sb-posix)
(defparameter *script-path* (namestring (truename *load-truename*)))

#|
  Normalize surrounding text whitespace for all parser entry points.
  Inputs: An input string.
  Outputs: A trimmed string.
  Used by: parse-number and read-values before validation.
|#
(defun trim-text (text)
  (string-trim '(#\Space #\Tab #\Return #\Newline) text))

#|
  Read one real value without permitting reader evaluation.
  Inputs: An input token string.
  Outputs: A double-float in range, or a condition describing invalid input.
  Used by: read-values and main in worker mode.
|#
(defun parse-number (text)
  #|
    Input is data: reader evaluation is disabled, and the complete token is checked.
    Treat user text as numeric data rather than allowing read-time code execution.
  |#
  (let ((*read-eval* nil) (*read-default-float-format* 'double-float))
    (multiple-value-bind (value end) (read-from-string text)
      (unless (and (realp value) (string= "" (trim-text (subseq text end))))
        (error "Expected one real number"))
      (let ((x (coerce value 'double-float)))
        (unless (<= -1000d0 x 1000d0) (error "Expected finite x in [-1000,1000]"))
        x))))

#|
  Compute sample values and read them through a pinned native-memory view.
  Inputs: A validated double-float x.
  Outputs: The approximate J0 value.
  Used by: main in a child SBCL process.
|#
(defun j0 (x)
  (let ((samples (make-array 16384 :element-type 'double-float)))
    (loop for k below (length samples)
          do (setf (aref samples k) (cos (* x (sin (/ (* pi (+ k 0.5d0)) 16384d0))))))
    #|
      SBCL-specific system-area pointers. Pin the owning vector so the GC
      cannot move it. sap+ counts bytes; each 8-byte read is in bounds.
    |#
    (sb-sys:with-pinned-objects (samples)
      (let ((base (sb-sys:vector-sap samples)))
        (/ (loop for k below (length samples)
                 sum (sb-sys:sap-ref-double (sb-sys:sap+ base (* k 8)) 0)
                   into total of-type double-float
                 finally (return total))
           16384d0)))))

#|
  Collect observations with a restart that skips a malformed value.
  Inputs: An input stream.
  Outputs: An ordered nonempty list, or a fatal condition.
  Used by: main before it starts worker processes.
|#
(defun read-values (stream)
  (let ((values nil) (count 0))
    (loop for line = (read-line stream nil nil) while line
          for text = (trim-text line)
          until (string= text "")
          unless (char= (char text 0) #\#)
          do (handler-bind
                 ((error (lambda (condition)
                           (format *error-output* "warning: ~A; skipped~%" condition)
                           (invoke-restart 'skip-value))))
               ;; Offer a precise recovery action that discards one bad value without discarding the entire input.
               (restart-case (push (parse-number text) values)
                 (skip-value () :report "Skip this malformed input value." nil)))
             (setf count (length values))
             (when (> count 4096) (error "At most 4096 values")))
    (or (nreverse values) (error "No valid input values"))))

#|
  Start asynchronous SBCL children and gather their result rows.
  Inputs: A bounded list of numeric observations.
  Outputs: CSV rows in input order; owned processes are cleaned up on unwinding.
  Used by: main for each worker-sized prefix of input.
|#
(defun batch (values)
  (let ((children nil))
    ;; Retain cleanup obligations while processes are launched and their rows are collected.
    (unwind-protect
         (progn
           ;; Launch all children in this group before waiting for any one result.
           (dolist (x values)
             (push (sb-ext:run-program
                    (namestring sb-ext:*runtime-pathname*)
                    (list "--script" *script-path* "--worker" (format nil "~,17F" x))
                    :wait nil :input nil :output :stream :error *error-output*)
                   children))
           (loop for child in (reverse children)
                 for row = (read-line (sb-ext:process-output child) nil nil)
;; Verify child completion before accepting its output line.
                 do (sb-ext:process-wait child)
                    (unless (and row (eq :exited (sb-ext:process-status child))
                                 (eql 0 (sb-ext:process-exit-code child)))
                      (error "Worker failed"))
                 collect row))
      (dolist (child children)
        (when (sb-ext:process-alive-p child) (sb-ext:process-kill child 15))
        (sb-ext:process-wait child)
        (sb-ext:process-close child)))))

#|
  Select help, child computation, or the full experiment.
  Inputs: The command-line argument list.
  Outputs: Result/console output, or a condition caught by the outer handler.
  Used by: The final handler-case entry expression.
|#
(defun main (args)
  (cond
    ((equal args '("--help"))
     (format t "Usage: sbcl --script bessel.lisp [INPUT|- [OUTPUT [WORKERS 1..16]]]~%"))
    ((and (= (length args) 2) (string= (first args) "--worker"))
     (let ((x (parse-number (second args))))
       (format t "~,17F,~,17F,~D~%" x (j0 x) (sb-posix:getpid))))
    (t
     (when (> (length args) 3) (error "Too many arguments"))
     (let* ((source (or (first args) "-"))
            (target (or (second args) "results.csv"))
            (jobs (parse-integer (or (third args) "2")))
            (values (progn
                      (unless (<= 1 jobs 16) (error "Workers must be 1..16"))
                      (if (string= source "-")
                          (progn
                            (format *error-output* "Enter one x per line; blank line or EOF finishes:~%")
                            (read-values *standard-input*))
                          (with-open-file (stream source) (read-values stream)))))
            (rows (loop for rest = values then (nthcdr (min jobs (length rest)) rest)
                        while rest append (batch (subseq rest 0 (min jobs (length rest)))))))
       ;; Write the complete CSV in a scope that closes the file on normal and exceptional exits.
       (with-open-file (stream target :direction :output :if-exists :supersede :if-does-not-exist :create)
         (write-line "x,j0,worker_pid" stream)
         (dolist (row rows) (write-line row stream)))
       (format t "Wrote ~D observations to ~A~%" (length rows) target)))))

;; Keep fatal conditions behind the readable command-line error boundary.
(handler-case (main (rest sb-ext:*posix-argv*))
  (error (condition)
    (format *error-output* "error: ~A~%" condition)
    (sb-ext:exit :code 1)))
