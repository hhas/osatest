//
//  main.m
//  osatest
//
//  Note: OSAKit's OSAScript class doesn't expose a public OSAID property, so is useless if
//  OpenScripting.framework's C APIs ever need to be used (e.g. for getting property names).
//  Therefore everything except creating AppleScript CIs (which OSALanguageInstance can do)
//  is done via gnarly old legacy C APIs, which is not ideal but is the only way that works.
//
//  TO DO: help text should recommend use of a `.unittest.scpt[d]` suffix for test scripts, and include an example shell script that recursively searches a folder for all files with `.unittest.scpt[d]` suffixes and passes them to osatest to run
//


#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>

#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>


#define TESTLIBRARYNAME     @"TestTools"

#define AEWRAP(aedesc)      ([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy: (aedesc)])
#define AESTRING(nsString)  ([NSAppleEventDescriptor descriptorWithString: (nsString)])
#define AEINT(n)            ([NSAppleEventDescriptor descriptorWithInt32: (n)])
#define AEBOOL(nsBool)      ([NSAppleEventDescriptor descriptorWithBoolean: (nsBool)])

#define AEEMPTYLIST()           ([NSAppleEventDescriptor listDescriptor])
#define AEADDTOLIST(desc, item) ([(desc) insertDescriptor: (item) atIndex: 0])

#define AEERRORMESSAGE(evt)     ([(evt) paramDescriptorForKeyword: keyErrorString].stringValue ?: @"")
#define AEERRORNUMBER(evt)      ([(evt) paramDescriptorForKeyword: keyErrorNumber].int32Value)
#define AERESULT(evt, descType) ([[(evt) paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType:(descType)])


#define VTNORMAL    @"\x1b[0m"
#define VTBOLD      @"\x1b[1m"
#define VTUNDER     @"\x1b[4m"
#define VTRED       @"\x1b[31m"
#define VTGREEN     @"\x1b[32m"
#define VTBLUE      @"\x1b[34m"

#define VTHEADING   (VTBOLD VTUNDER)
#define VTPASSED    (VTBOLD VTGREEN)
#define VTFAILED    (VTBOLD VTRED)

// test outcome constants defined by TestTools's TestSupport sub-library
#define _NOSTATUS  (-1)
#define _BUG       (0)
#define _SUCCESS   (1)
#define _FAILURE   (2)
#define _BROKEN    (3)
#define _SKIPPED   (4)
#define _SKIPSUITE (9)


typedef struct {
    int bug;
    int success;
    int failure;
    int broken;
    int skipped;
} StatusCounts; // tally of test outcomes for final summary


/******************************************************************************/
// print to stdout/stderr

// determine if stdout is connected to a terminal (if it is, test reports will be formatted accordingly)
int terminalColumns(void) {
    int width = -1;
    struct winsize ws;
    int fd = open("/dev/tty", O_RDONLY);
    if (fd < 0) return -1;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) width = (int)ws.ws_col;
    close(fd);
    return width;
}

NSString *sanitizeString(NSString *s) {
    // U+0000—U+001F (C0 controls), U+007F (delete), and U+0080—U+009F
    static NSRegularExpression *pattern = nil;
    static BOOL useStyles;
    if (pattern == nil) {
        pattern = [NSRegularExpression regularExpressionWithPattern: @"[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1a\\x1c-\\x1f\\x7f-\\u009f]"
                                                            options: 0 error: nil];
        useStyles = terminalColumns() != -1;
    }
    s = [s stringByReplacingOccurrencesOfString: @"\r" withString: @"\n"];
    return [pattern stringByReplacingMatchesInString: s options: 0 range: NSMakeRange(0, s.length)
                                        withTemplate: (useStyles ? (VTRED @"¿" VTNORMAL) : @"¿")];
}

void logErr(NSString *format, ...) { // writes message to stderr
    va_list argList;
    va_start (argList, format);
    NSString *message = [[NSString alloc] initWithFormat: format arguments: argList];
    va_end (argList);
    fputs(sanitizeString(message).UTF8String, stderr);
    fflush(stderr);
}

void logOut(NSString *format, ...) { // writes message to stdout
    va_list argList;
    va_start (argList, format);
    NSString *message = [[NSString alloc] initWithFormat: format arguments: argList];
    va_end (argList);
    fputs(sanitizeString(message).UTF8String, stdout);
    fflush(stdout);
}


// if an error occurs during script execution, OSAExecute, etc set error on CI then return errOSAScriptError;
// OSAScriptError must then be called to extract those details; use the following convenience functions to
// retrieve the most commonly used details (error number and message) and print them to stderr

OSAError scriptErrorNumber(ComponentInstance ci) {
    AEDesc desc = {0,0};
    OSAError err = OSAScriptError(ci, kOSAErrorNumber, typeSInt32, &desc);
    if (err != noErr) return err;
    return AEWRAP(&desc).int32Value;
}

NSString *scriptErrorMessage(ComponentInstance ci) {
    AEDesc desc = {0,0};
    OSAError err = OSAScriptError(ci, kOSAErrorMessage, typeUnicodeText, &desc);
    if (err != noErr) return [NSString stringWithFormat: @"OSAError %i", err];
    return AEWRAP(&desc).stringValue;
}

NSString *scriptErrorDescription(ComponentInstance ci) { // get details for errOSAScriptError (i.e. osatest/TestTools bug)
    return [NSString stringWithFormat: @"script error %i: %@", scriptErrorNumber(ci), scriptErrorMessage(ci)];
}


/******************************************************************************/
// introspect test script for [script] objects with `suite_` prefix and handlers within those objects with `test_` prefix

NSArray<NSString *> *filterNamesByPrefix(NSAppleEventDescriptor *namesDesc, NSString *prefix) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSInteger i = 1; i <= namesDesc.numberOfItems; i++) {
        NSString *name = [namesDesc descriptorAtIndex: i].stringValue; // (nil = keyword-based name, which is always ignored)
        if ([name.lowercaseString hasPrefix: prefix] && name.length > prefix.length) [names addObject: name];
    }
    return names.copy;

}


NSArray<NSString *> *suiteNamesForScript(ComponentInstance ci, OSAID scriptID) {
    AEDescList resultingNames;
    OSAError err = OSAGetPropertyNames(ci, 0, scriptID, &resultingNames);
    if (err != noErr) {
        logErr(@"Failed to get suite names (error %i).\n", err);
        return nil;
    }
    return filterNamesByPrefix(AEWRAP(&resultingNames), @"suite_");
}


NSArray<NSString *> *testNamesForSuiteName(ComponentInstance ci, OSAID scriptID, NSString *suiteName) {
    OSAID valueID;
    if (OSAGetProperty(ci, 0, scriptID, AESTRING(suiteName).aeDesc, &valueID) != noErr) return nil;
    // TO DO: check scriptValueID is actually typeScript? or is OSAGetHandlerNames guaranteed to fail if it isn't?
    AEDescList resultingNames;
    NSArray<NSString *> *names = nil;
    if (OSAGetHandlerNames(ci, 0, valueID, &resultingNames) == noErr) {
        names = filterNamesByPrefix(AEWRAP(&resultingNames), @"test_");
    }
    OSADispose(ci, valueID);
    return names;
}


/******************************************************************************/
// call script handler support

// an AS identifier can be pretty much anything as long as it's wrapped in pipes, e.g. `|name|`, `|foo 123!|`
NSString *sanitizeIdentifier(NSString *name) {
    NSString *newName = [[name stringByReplacingOccurrencesOfString: @"\\" withString: @"\\\\"]
                         stringByReplacingOccurrencesOfString: @"|" withString: @"\\|"];
    if (![newName isEqualToString: name]) newName = [NSString stringWithFormat: @"|%@|", newName];
    return newName;
}


// build an Apple event for invoking an AS handler with an identifier-based name and positional parameters
NSAppleEventDescriptor *newSubroutineEvent(NSString *name, NSAppleEventDescriptor *paramsList) {
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass: kASAppleScriptSuite
                                                                             eventID: kASSubroutineEvent
                                                                    targetDescriptor: nil
                                                                            returnID: kAutoGenerateReturnID
                                                                       transactionID: kAnyTransactionID];
    [event setParamDescriptor: AESTRING(name) forKeyword: keyASSubroutineName];
    [event setParamDescriptor: paramsList forKeyword: keyDirectObject];
    return event;
}


// calls a subroutine and returns an Apple event containing its response
OSAError callSubroutine(ComponentInstance ci, OSAID scriptID, NSString *handlerName,
                        NSAppleEventDescriptor *paramsList, NSAppleEventDescriptor * __autoreleasing *replyEvent) {
    *replyEvent = [NSAppleEventDescriptor appleEventWithEventClass: kCoreEventClass
                                                           eventID: kAEAnswer
                                                  targetDescriptor: nil
                                                          returnID: kAutoGenerateReturnID
                                                     transactionID: kAnyTransactionID];
    NSAppleEventDescriptor *setRawEvent = newSubroutineEvent(handlerName, paramsList);
    OSAError err = OSADoEvent(ci, setRawEvent.aeDesc, scriptID, 0, (AEDesc *)((*replyEvent).aeDesc));
    if (err == noErr) err = AEERRORNUMBER(*replyEvent); // if event was dispatched successfully, check reply event for any error
    return err;
}


/******************************************************************************/
// perform a single unit text

// run a single unit test, returning scriptID for a TestReport script object containing the raw test results
OSAError callTestTools(ComponentInstance ci, OSAID scriptID,
                       NSString *suiteName, NSString *handlerName, int lineWidth, OSAID *reportScriptID) {
    // add a new code-generated __performunittest__ handler to test script
    
    // TO DO: problem: something is tickling a deep rooted (bytecode-related?) Heisenbug in AS that causes bizarre errors to manifest on occasion when the unittest script is run within SE (or osascript), rather than directly from Terminal
    
    // note: for this to work correctly, the TestTools instance used to run the test must be the same instance that the unittest script imported itself (__performunittest__ sets properties within TestTools that will be used by `assert` handlers when the test handler is called)
    
    // one way to avoid augmenting context would be for unittest script to use `property parent : a ref to script "TestTools"`; that would allow __performunittestforsuite__ message to be dispatched to unittest script but handled by TestTools
    
    NSString *code = [NSString stringWithFormat:
                      @"to |__performunittest__|(|_paramslist_|)\n"
                      @"  return script \"" TESTLIBRARYNAME @"\"'s |__performunittestforsuite__|(my %@, |_paramslist_|)\n"
                      @"end |__performunittest__|", sanitizeIdentifier(suiteName)];
    OSAError err = OSACompile(ci, AESTRING(code).aeDesc, kOSAModeAugmentContext, &scriptID);
    if (err != noErr) {
        logErr(@"Failed to add __performunittest__ (error %i)\n", err);
        return err;
    }
    // build AppleEvent to invoke the __performunittest__ handler
    NSAppleEventDescriptor *testData = AEEMPTYLIST();
    AEADDTOLIST(testData, AESTRING(suiteName));
    AEADDTOLIST(testData, AESTRING(handlerName));
    AEADDTOLIST(testData, AEINT(lineWidth));
    NSAppleEventDescriptor *params = AEEMPTYLIST();
    AEADDTOLIST(params, testData);
    NSAppleEventDescriptor *event = newSubroutineEvent(@"__performunittest__", params);
    // call test script's code-generated __performunittest__ handler passing test data;
    // it then calls TestTools's __performunittestforsuite__ with the `suite_NAME` object and test data
    // __performunittestforsuite__ should always return a TestReport object, which appears as a new scriptID
    err = OSAExecuteEvent(ci, event.aeDesc, scriptID, 0, reportScriptID);
    if (err == errOSAScriptError) { // i.e. osatest/TestTools bug
        logErr(@"Failed to perform %@'s %@ (%@).", suiteName, handlerName, scriptErrorDescription(ci));
    } else if (err != noErr) { // i.e. TestTools bug
        logErr(@"Failed to perform %@'s %@: OSAExecuteEvent error: %i.\n", suiteName, handlerName, err); // e.g. -1708 = event not handled
    }
    return err;
}


// use the TestReport object returned by invokeTestTools to render the finished test report
OSAError printTestReport(ComponentInstance ci, OSAID scriptID, int lineWidth, int *testStatus) {
    OSAError err = noErr; // note: report generation should never fail, but check for errors anyway in case TestTools is buggy
    // call TestReport's nextrawdata and updaterawdata methods to convert each bit of raw data gathered by asserts to literal text
    while (1) { // loop breaks below when TestReport's nextrawdata iterator is exhausted
        // invoke TestReport's nextrawdata method; the result is an OSAID for a single AS value to convert
        NSAppleEventDescriptor *getRawEvent = newSubroutineEvent(@"nextrawdata", AEEMPTYLIST());
        OSAID valueID;
        err = OSAExecuteEvent(ci, getRawEvent.aeDesc, scriptID, 0, &valueID);
        if (err != noErr) {
            if (err == errOSAScriptError) {
                if (scriptErrorNumber(ci) == 6502) break; // iterator raises error 6502 to indicate it's exhausted, so exit loop
                logErr(@"Failed to get next raw value (%@).", scriptErrorDescription(ci)); // else it's a bug in TestSupport's nextrawdata iterator
            } else if (err != noErr) { // some other bug (e.g. -1708 = event not handled, i.e. incorrect handler name)
                logErr(@"Failed to get next raw value (error: %i).\n", err);
            }
            return err;
        }
        // convert the raw AS value to its literal representation
        AEDesc literalValueDesc;
        err = OSADisplay(ci, valueID, typeUnicodeText, 0, &literalValueDesc);
        OSADispose(ci, valueID);
        if (err != noErr) {
            logErr(@"Failed to format raw value (error: %i).\n", err);
            return err;
        }
        // pass the formatted text back to TestReport
        NSAppleEventDescriptor *params = AEEMPTYLIST();
        AEADDTOLIST(params, AEWRAP(&literalValueDesc));
        NSAppleEventDescriptor *replyEvent = nil;
        err = callSubroutine(ci, scriptID, @"updaterawdata", params, &replyEvent);
        if (err != noErr) { // bug in TestReport's updaterawdata handler
            logErr(@"Failed to update raw value (error %i). %@\n", err, AEERRORMESSAGE(replyEvent));
            return err;
        }
    }
    // once all raw values have been converted to text, tell TestReport to to render the test report
    NSAppleEventDescriptor *replyEvent = nil;
    err = callSubroutine(ci, scriptID, @"renderreport", AEEMPTYLIST(), &replyEvent);
    if (err != noErr) { // bug in TestReport's renderreport handler
        logErr(@"Report generation failed (error %i). %@\n", err, AEERRORMESSAGE(replyEvent));
        return err;
    }
    NSAppleEventDescriptor *reportRecord = AERESULT(replyEvent, typeAERecord);
    *testStatus = [reportRecord descriptorForKeyword: 'Stat'].int32Value;
    NSString *report = [reportRecord descriptorForKeyword: 'Repo'].stringValue;
    if (report == nil) {
        logErr(@"Report generation failed (no text was returned).\n"); // bug in TestReport's renderreport handler
        return 1;
    }
    logOut(@"%@\n", report);
    return noErr;
}


// create a new, clean AppleScript component instance, load the unit test script into it, and perform a single test
OSAError runOneTest(OSALanguage *language, AEDesc scriptData, NSURL *scriptURL,
                    NSString *suiteName, NSString *handlerName, int lineWidth, int *status) {
    @autoreleasepool {
        OSALanguageInstance *li = [OSALanguageInstance languageInstanceWithLanguage: language];
        OSAID scriptID, reportScriptID = 0;
        OSAError err = OSALoadScriptData(li.componentInstance, &scriptData, (__bridge CFURLRef)(scriptURL),
                                         kOSAModeCompileIntoContext, &scriptID);
        if (err != noErr) return err; // (shouldn't fail as script's already been successfully loaded once)
        err = callTestTools(li.componentInstance, scriptID, suiteName, handlerName, lineWidth, &reportScriptID);
        if (err == noErr) {
            err = printTestReport(li.componentInstance, reportScriptID, lineWidth, status);
            if (err != noErr) logErr(@"Failed to generate report (error %i).\n", err); // i.e. TestTools bug
        }
        OSADispose(li.componentInstance, reportScriptID);
        OSADispose(li.componentInstance, scriptID);
        return err;
    }
}


/******************************************************************************/
// main


int runTestFile(NSURL *scriptURL) {
    @autoreleasepool {
        AEDesc scriptDesc = {0,0};
        OSAID scriptID = 0;
        OSALanguage *language = [OSALanguage languageForName: @"AppleScript"];
        OSALanguageInstance *languageInstance = [OSALanguageInstance languageInstanceWithLanguage: language];
        #define FAILRETURN {OSADispose(languageInstance.componentInstance, scriptID); AEDisposeDesc(&scriptDesc); return 1;}
        int lineWidth = terminalColumns(); // (-1 = not connected to a terminal)
        logOut(@"%@osatest '%@'%@\n",
               (lineWidth == -1 ? @"" : VTHEADING),
               [scriptURL.path stringByReplacingOccurrencesOfString: @"'" withString:@"'\\''"],
               (lineWidth == -1 ? @"" : VTNORMAL));
        // introspect the unittest.scpt, getting names of all top-level script objects named `suite_NAME`
        // (note: this could quite easily be made recursive, allowing users to group suites into sub-suites if they wish, but for now just go with simple flat `suite>test` hierarchy and see how well that works in practice)
        OSAError err = OSAGetScriptDataFromURL((__bridge CFURLRef)(scriptURL), 0, 0, &scriptDesc);
        if (err != noErr) {
            logErr(@"Failed to read script (error %i).\n", err); // TO DO: better error reporting needed, e.g. if file not found or couldn't be read as script (currently returns -4960, unknown CF error, which is useless); probably need to check first if valid file path, then try OSAGetStorageType() to see if it's valid OSA script
            FAILRETURN;
        }
        err = OSALoadScriptData(languageInstance.componentInstance, &scriptDesc, (__bridge CFURLRef)(scriptURL), kOSAModeCompileIntoContext, &scriptID);
        if (err != noErr) {
            logErr(@"Failed to load script (error %i).\n", err); // TO DO: check what error is reported if not AppleScript storage type, and improve error reporting
            FAILRETURN;
        }
        NSArray<NSString *> *suiteNames = suiteNamesForScript(languageInstance.componentInstance, scriptID);
        if (suiteNames == nil) FAILRETURN;
        // run the unit tests
        // important: each test must run in its own CI to avoid sharing TIDs, library instances, etc with other tests
        NSString *testTitleTemplate = lineWidth == -1 ? @"%i.%i %@'s %@: " : @"\x1b[1m%i.%i %@'s %@\x1b[0m: ";
        StatusCounts statusCounts = {0,0,0,0,0};
        NSInteger suiteIndex = 0;
        NSDate *startTime = [NSDate date];
        logOut(@"Begin tests at %@\n", startTime);
        for (NSString *suiteName in suiteNames) {
            ++suiteIndex;
            NSArray<NSString *> *handlerNames = testNamesForSuiteName(languageInstance.componentInstance, scriptID, suiteName);
            NSString *suiteTitle = [suiteName substringFromIndex:6];
            NSInteger testIndex = 0;
            for (NSString *handlerName in handlerNames) {
                logOut(testTitleTemplate, suiteIndex, ++testIndex, suiteTitle, [handlerName substringFromIndex:5]);
                int status = _NOSTATUS; // 0 = TestTools failed (bug)
                err = runOneTest(language, scriptDesc, scriptURL, suiteName, handlerName, lineWidth, &status);
                if (err != noErr) FAILRETURN;
                if (status == _SKIPSUITE) { // entire suite was deliberately skipped by suite's configure_skipTests()
                    statusCounts.skipped++; // note: this doesn't distinguish between skipped tests and skipped suites; it's just to provide reminder in final result line that *something* got skipped
                    handlerNames = nil;
                    break; // skip rest of this suite and proceed to next one
                }
                switch (status) {
                    case _SUCCESS:
                        statusCounts.success++;
                        break;
                    case _FAILURE:
                        statusCounts.failure++;
                        break;
                    case _BROKEN:
                        statusCounts.broken++;
                        break;
                    case _NOSTATUS: // no asserts were performed by test handler, so report it as 'skipped'
                    case _SKIPPED:  // test handler was deliberately skipped by suite's configure_skipTests()
                        statusCounts.skipped++;
                        break;
                    default:
                        logErr(@"Invalid test status: %i\n", status);
                        FAILRETURN;
                }
            }
        }
        NSDate *endedTime = [NSDate date];
        logOut(@"Ended tests at %@ (%0.3fs)\n", endedTime, [endedTime timeIntervalSinceDate: startTime]);
        logOut(@"%@Result: %i tests passed, %i failed, %i broken, %i skipped.%@\n",
               (lineWidth == -1 ? @"" : (statusCounts.failure == 0 && statusCounts.broken == 0 ? VTPASSED : VTFAILED)),
               statusCounts.success, statusCounts.failure, statusCounts.broken, statusCounts.skipped,
               (lineWidth == -1 ? @"" : VTNORMAL));
        return 0;
    }
}



int main(int argc, const char * argv[]) {
    if (argc < 2 || strcmp(argv[1], "-h") == 0) {
        printf("Usage: osatest FILE ...\n");
    } else {
        for (int i = 1; i < argc; i++) { // run the specified unit test file(s)
            NSURL *scriptURL = [NSURL fileURLWithFileSystemRepresentation:argv[i] isDirectory: NO relativeToURL: nil];
            if (scriptURL == nil) return fnfErr;
            int err = runTestFile(scriptURL);
            if (err != noErr) return err;
        }
    }
    return 0;
}

