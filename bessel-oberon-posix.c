/* Checked POSIX/stdio adapter for Bessel.Mod. No Bessel mathematics lives here.
   OBC generates the primitive-call wrappers when linked with obc -C.
   File descriptors and stream ownership stay in this adapter. */
#define _POSIX_C_SOURCE 200809L
#include <ctype.h>
#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static FILE *input, *output;
static struct { int read, write; pid_t pid; } slots[16];
static int initialized;

/* Open input and initialize descriptor sentinels.
   Input: path ("-" means stdin). Output: success flag. Called by OpenInput. */
int bo_input(const char *path) {
    for (int i=0; i<16; ++i) slots[i].read=slots[i].write=-1;
    initialized=1;
    input=strcmp(path,"-") ? fopen(path,"r") : stdin;
    if (input==stdin && isatty(STDIN_FILENO)) fputs("Enter values; blank line finishes.\n",stderr);
    return input!=NULL;
}

/* Fill one bounded line without silently splitting an overlong observation.
   Inputs: destination and capacity. Output: length/-1 EOF/-2 failure.
   Called by ReadLine; the Oberon Trim procedure handles string cleanup. */
int bo_line(char *line, int capacity) {
    if (!fgets(line,capacity,input)) return ferror(input) ? -2 : -1;
    size_t n=strlen(line);
    if (n==(size_t)capacity-1 && line[n-1]!='\n' && !feof(input)) return -2;
    return (int)n;
}

/* Parse the complete token into caller-owned storage.
   Inputs: string and double pointer. Output: success flag and value.
   Called by Parse because OBC's Conv.LongRealVal cannot report partial parses. */
int bo_parse(const char *line, double *value) {
    char *end; errno=0; *value=strtod(line,&end);
    return end!=line && !*end && !errno && isfinite(*value) && fabs(*value)<=1000;
}

/* Reserve a pipe for a bounded slot.
   Input: slot 0..15. Output: success flag. Called by Pipe before Fork. */
int bo_pipe(int slot) {
    int pair[2]; if (pipe(pair)) return 0;
    slots[slot].read=pair[0]; slots[slot].write=pair[1]; return 1;
}

/* Fork and close pipe ends that each process does not own.
   Input: slot. Output: fork result. Called by Fork to create real OS workers. */
int bo_fork(int slot) {
    pid_t pid=fork();
    if (pid==0) {
        for (int i=0;i<16;++i) {
            if (slots[i].read>=0) close(slots[i].read);
            if (i!=slot && slots[i].write>=0) close(slots[i].write);
        }
    } else if (pid>0) {
        slots[slot].pid=pid; close(slots[slot].write); slots[slot].write=-1;
    }
    return (int)pid;
}

/* Transfer exactly one native double, handling interrupts and short I/O.
   Inputs: descriptor, memory pointer, direction. Output: success flag.
   Called by Send and Collect; pointer arithmetic advances only within a double. */
static int transfer(int fd, double *value, int sending) {
    char *p=(char *)value; size_t left=sizeof *value;
    while (left) {
        ssize_t n=sending ? write(fd,p,left) : read(fd,p,left);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return 0;
        p+=n; left-=(size_t)n;
    }
    return 1;
}

/* Send a computed value and terminate without flushing inherited streams.
   Inputs: slot and value. Output: child exit code. Called by Send only in child. */
void bo_send(int slot, double value) {
    int ok=transfer(slots[slot].write,&value,1);
    close(slots[slot].write); _exit(ok ? 0 : 1);
}

/* Receive a result and reap its child even if the read fails.
   Inputs: slot and result pointer. Output: success flag and double.
   Called by Collect at batch boundaries; failed status remains a parent error. */
int bo_collect(int slot, double *value) {
    int ok=transfer(slots[slot].read,value,0), status; pid_t got;
    close(slots[slot].read); slots[slot].read=-1;
    do { got=waitpid(slots[slot].pid,&status,0); } while (got<0 && errno==EINTR);
    slots[slot].pid=0;
    return ok && got>0 && WIFEXITED(status) && !WEXITSTATUS(status);
}

/* Open the target and write its CSV schema.
   Input: path. Output: success flag. Called by OpenOutput after computation. */
int bo_output(const char *path) {
    output=fopen(path,"w");
    return output && fputs("x,j0,worker_pid\n",output)>=0;
}
/* Format one ordered row at double precision.
   Inputs: x, J0, PID. Output: success flag. Called by Row in the parent. */
int bo_row(double x, double y, int pid) { return fprintf(output,"%.17g,%.17g,%d\n",x,y,pid)>0; }
/* Check final buffered output. Input: output stream. Output: success flag.
   Called by CloseOutput so disk errors cannot be reported as success. */
int bo_close_output(void) { int ok=fclose(output)==0; output=NULL; return ok; }
/* Release adapter-owned resources after ordinary completion or failure.
   Input: static state. Output: no surviving child/descriptor. Called by Cleanup. */
void bo_cleanup(void) {
    if (initialized) for (int i=0;i<16;++i) {
        if (slots[i].read>=0) close(slots[i].read);
        if (slots[i].write>=0) close(slots[i].write);
        if (slots[i].pid>0) {
            kill(slots[i].pid,SIGTERM);
            while (waitpid(slots[i].pid,NULL,0)<0 && errno==EINTR) {}
        }
    }
    if (input && input!=stdin) fclose(input);
    if (output) fclose(output);
    input=output=NULL;
}

/* Print one terminal line. Inputs: text and stderr flag. Output: text.
   Called by Message for usage, progress, invalid observations, and errors. */
void bo_message(const char *text, int error) { fprintf(error ? stderr : stdout,"%s\n",text); }
