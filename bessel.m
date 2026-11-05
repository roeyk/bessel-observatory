/*
  Bessel Observatory: validate input, evaluate the common midpoint integral in child processes, then save CSV.
  The parent owns file I/O and result ordering; children perform the numerical work.
  The common CLI accepts an input file or -, an output filename, and a worker limit from 1 to 16.
  Objective-C with Foundation (macOS or GNUstep), manual retain/release compatible.
*/
#import <Foundation/Foundation.h>
#include <math.h>
#include <unistd.h>

/*
  Represent an ordinary application failure as a readable Objective-C exception.
  Inputs: A message string.
  Outputs: No normal return; an ObservatoryError is thrown.
  Used by: Validation, process and output checks inside Observatory methods.
*/
static void Fail(NSString *message) {
    @throw [NSException exceptionWithName:@"ObservatoryError" reason:message userInfo:nil];
}
/*
  Parse one complete numeric token with a fixed decimal separator.
  Inputs: An NSString from input or a worker argument.
  Outputs: A finite bounded double, or an ObservatoryError.
  Used by: run: when accepting input and entering worker mode.
*/
static double Number(NSString *text) {
    // Use Foundation parsing while checking that no unconsumed token suffix remains.
    NSScanner *scanner = [NSScanner scannerWithString:text];
    [scanner setLocale:@{NSDecimalSeparator: @"."}];
    double x;
    if (![scanner scanDouble:&x] || ![scanner isAtEnd] || !isfinite(x) || fabs(x) > 1000)
        Fail(@"expected finite x in [-1000,1000]");
    return x;
}
// Expose one operation for a worker result and one for the overall command-line workflow.
@interface Observatory : NSObject
+ (NSString *)observe:(double)x;
+ (void)run:(NSArray *)args;
@end
@implementation Observatory
/*
  Compute and serialize one observation in the current process.
  Inputs: One validated double x.
  Outputs: An autoreleased NSString containing x, J0 and the worker OS PID.
  Used by: run: when the executable is launched with --worker.
*/
+ (NSString *)observe:(double)x {
    double sum = 0, samples[16384];
    for (int k = 0; k < 16384; ++k) samples[k] = cos(x * sin(acos(-1) * (k + 0.5) / 16384));
    /*
      C pointers coexist with Objective-C object references. end is a legal
      one-past-the-array pointer and is never dereferenced.
    */
    for (const double *cursor = samples, *end = samples + 16384; cursor != end; ++cursor)
        sum += *cursor;
    return [NSString stringWithFormat:@"%.17g,%.17g,%ld\n", x, sum / 16384, (long)getpid()];
}
/*
  Select help, worker execution, or the full parent experiment.
  Inputs: The Foundation process-argument array including the executable name.
  Outputs: CSV/console output; failed operations throw to the entry boundary.
  Used by: main inside the autorelease pool.
*/
+ (void)run:(NSArray *)args {
    NSUInteger n = [args count];
    if (n == 2 && [[args objectAtIndex:1] isEqual:@"--help"]) {
        puts("Usage: bessel-objc [INPUT|- [OUTPUT [WORKERS 1..16]]]"); return;
    }
    if (n == 3 && [[args objectAtIndex:1] isEqual:@"--worker"]) {
        fputs([[self observe:Number([args objectAtIndex:2])] UTF8String], stdout); return;
    }
    if (n > 4) Fail(@"too many arguments");
    NSString *source = n > 1 ? [args objectAtIndex:1] : @"-";
    NSString *target = n > 2 ? [args objectAtIndex:2] : @"results.csv";
    double requested = n > 3 ? Number([args objectAtIndex:3]) : 2;
    if (requested < 1 || requested > 16 || trunc(requested) != requested) Fail(@"workers must be 1..16");
    NSUInteger jobs = (NSUInteger)requested;
    FILE *input = [source isEqual:@"-"] ? stdin : fopen([source fileSystemRepresentation], "r");
    if (!input) Fail(@"cannot open input");
    if (input == stdin) fputs("Enter one x per line; blank line or EOF finishes:\n", stderr);
    NSMutableArray *values = [NSMutableArray array];
    char *buffer = NULL; size_t capacity = 0;
    @try {
        // Read complete UTF-8 lines and normalize their surrounding whitespace.
        while (getline(&buffer, &capacity, input) >= 0) {
            NSString *text = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!text) Fail(@"input is not UTF-8");
            if (![text length]) break;
            if ([text hasPrefix:@"#"]) continue;
            @try { [values addObject:[NSNumber numberWithDouble:Number(text)]]; }
            // Recover from an invalid input token while retaining later usable observations.
            @catch (NSException *e) { fprintf(stderr, "warning: %s; skipped\n", [[e reason] UTF8String]); }
            if ([values count] > 4096) Fail(@"at most 4096 values");
        }
        if (ferror(input)) Fail(@"input read failed");
    } @finally { free(buffer); if (input != stdin) fclose(input); }
    if (![values count]) Fail(@"no valid input values");
    NSMutableString *rows = [NSMutableString stringWithString:@"x,j0,worker_pid\n"];
    for (NSUInteger first = 0; first < [values count]; first += jobs) {
        NSMutableArray *children = [NSMutableArray array];
        @try {
            for (NSUInteger i = first; i < MIN(first + jobs, [values count]); ++i) {
                // Create a separate executable process and its dedicated result pipe.
                NSTask *child = [[[NSTask alloc] init] autorelease];
                NSPipe *pipe = [NSPipe pipe];
                [child setLaunchPath:[[NSBundle mainBundle] executablePath]];
                [child setArguments:@[@"--worker", [[values objectAtIndex:i] stringValue]]];
                [child setStandardOutput:pipe];
                [child setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
                // Launch now and collect later so the entire bounded group computes concurrently.
                [child launch]; [children addObject:child];
            }
            for (NSTask *child in children) {
                // Drain each result pipe before waiting and accepting the child result.
                NSData *data = [[[child standardOutput] fileHandleForReading] readDataToEndOfFile];
                [child waitUntilExit];
                NSString *row = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
                if ([child terminationStatus] || ![row length]) Fail(@"worker failed");
                [rows appendString:row];
            }
        } @finally {
            for (NSTask *child in children) { if ([child isRunning]) [child terminate]; [child waitUntilExit]; }
        }
    }
    // Translate a Foundation file-write error into the same readable application failure path.
    NSError *error = nil;
    if (![rows writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:&error])
        Fail([error localizedDescription]);
    printf("Wrote %lu observations to %s\n", (unsigned long)[values count], [target UTF8String]);
}
@end
/*
  Create Foundation lifetime management and provide the final exception boundary.
  Inputs: The process arguments obtained through NSProcessInfo.
  Outputs: A successful return or a diagnostic and status 1.
  Used by: The operating system when the executable starts.
*/
int main(void) {
    @autoreleasepool {
        @try { [Observatory run:[[NSProcessInfo processInfo] arguments]]; }
        @catch (NSException *e) { fprintf(stderr, "error: %s\n", [[e reason] UTF8String]); return 1; }
    }
    return 0;
}
