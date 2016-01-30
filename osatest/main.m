//
//  main.m
//  osatest
//
//  note: OSAKit's OSAScript class doesn't expose a public scriptID property, so is unusable
//  if OpenScripting.framework-only C APIs need to be used for anything (which they are);
//  thus everything except creating AppleScript ComponentInstances is done old-school
//
//  TO DO: reenable deprecation warnings once logAEDesc is no longer needed and can be deleted
//
//  TO DO: what to do about control chars appearing in test reports (particularly NUL)?
//
//  TO DO: consider making `.unittest.scpt[d]` suffix mandatory, so that when passed a .scptd bundle (e.g. a library script) it can be searched automatically for embedded unit tests
//
// TO DO: check that runOneTest() and its sub-calls always log error message before returning error code


#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>

#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>


#define AEWRAP(aedesc)      ([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy: (aedesc)])
#define AESTRING(nsString)  ([NSAppleEventDescriptor descriptorWithString: (nsString)])
#define AEINT(n)            ([NSAppleEventDescriptor descriptorWithInt32: (n)])
#define AEBOOL(nsBool)      ([NSAppleEventDescriptor descriptorWithBoolean: (nsBool)])

#define AEEMPTYLIST             ([NSAppleEventDescriptor listDescriptor])
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

// constants defined by TestLib's TestSupport sub-library
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
} StatusCounts;

/******************************************************************************/
// write to stdout/stderr

void logAEDesc(char *labelCStr, AEDesc *aeDescPtr) { // DEBUG // TO DO: delete once no longer needed
    Handle h;
    AEPrintDescToHandle((aeDescPtr), &h);
    fprintf(stderr, "%s%s\n", (labelCStr), *h);
    DisposeHandle(h); // deprecated API
}

void logErr(NSString *format, ...) { // writes message to stderr
    va_list argList;
    va_start (argList, format);
    NSString *message = [[NSString alloc] initWithFormat: format arguments: argList];
    va_end (argList);
    fputs(message.UTF8String, stderr);
}

void logOut(NSString *format, ...) { // writes message to stdout
    va_list argList;
    va_start (argList, format);
    NSString *message = [[NSString alloc] initWithFormat: format arguments: argList];
    va_end (argList);
    fputs(message.UTF8String, stdout);
}


// get/write ScriptError info


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


void logScriptError(ComponentInstance ci, NSString *message) { // writes OSA script error (i.e. osatest/TestLib bug) to stderr
    logErr(@"%@ (script error %i: %@)\n", message, scriptErrorNumber(ci), scriptErrorMessage(ci));
}


/******************************************************************************/
// introspection

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
    if (OSAGetPropertyNames(ci, 0, scriptID, &resultingNames) != noErr) return nil;
    return filterNamesByPrefix(AEWRAP(&resultingNames), @"suite_");
}


NSArray<NSString *> *testNamesForSuiteName(ComponentInstance ci, OSAID scriptID, NSString *suiteName) {
    OSAID scriptValueID;
    if (OSAGetProperty(ci, 0, scriptID, AESTRING(suiteName).aeDesc, &scriptValueID) != noErr) return nil;
    // TO DO: check scriptValueID is actually typeScript? or is OSAGetHandlerNames guaranteed to fail if it isn't?
    AEDescList resultingNames;
    NSArray<NSString *> *names = nil;
    if (OSAGetHandlerNames(ci, 0, scriptValueID, &resultingNames) == noErr) {
        names = filterNamesByPrefix(AEWRAP(&resultingNames), @"test_");
    }
    OSADispose(ci, scriptValueID);
    return names;
}


/******************************************************************************/
// call script handler support

NSString *sanitizeIdentifier(NSString *name) {
    NSString *newName = [[name stringByReplacingOccurrencesOfString: @"\\" withString: @"\\\\"]
                         stringByReplacingOccurrencesOfString: @"|" withString: @"\\|"];
    if (![newName isEqualToString: name]) newName = [NSString stringWithFormat: @"|%@|", newName];
    return newName;
}


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
    if (err == noErr) err = [*replyEvent paramDescriptorForKeyword: keyErrorNumber].int32Value;
    return err;
}


/******************************************************************************/
// perform a single unit text


// run a single unit test, returning scriptID for resultant TestReport script object
OSAError invokeTestLib(ComponentInstance ci, OSAID scriptID,
                       NSString *suiteName, NSString *handlerName, int lineWidth, OSAID *reportScriptID) {
    // add a new code-generated __performunittest__ handler to test script
    NSString *escapedSuiteName = sanitizeIdentifier(suiteName);
    NSString *code = [NSString stringWithFormat:
                      @"to __performunittest__(|params|)\n"
                      @"  return script \"TestLib\"'s __performunittestforsuite__(my (%@), (|params|))\n"
                      @"end __performunittest__", escapedSuiteName];
    OSAError err = OSACompile(ci, AESTRING(code).aeDesc, kOSAModeAugmentContext, &scriptID);
    if (err != noErr) {
        logErr(@"Failed to add __performunittest__\n");
        OSADispose(ci, scriptID);
        return err;
    }
    // build AppleEvent to invoke the __performunittest__ handler
    NSAppleEventDescriptor *testData = AEEMPTYLIST;
    AEADDTOLIST(testData, AESTRING(suiteName));
    AEADDTOLIST(testData, AESTRING(handlerName));
    AEADDTOLIST(testData, AEINT(lineWidth));
    NSAppleEventDescriptor *params = AEEMPTYLIST;
    [params insertDescriptor: testData atIndex: 0];
    NSAppleEventDescriptor *event = newSubroutineEvent(@"__performunittest__", params);
    // call test script's code-generated __performunittest__ handler passing test data;
    // it then calls TestLib's __performunittestforsuite__ with the `suite_NAME` object and test data
    // __performunittestforsuite__ should always return a TestReport object, which appears as a new scriptID
    err = OSAExecuteEvent(ci, event.aeDesc, scriptID, 0, reportScriptID);
    if (err == errOSAScriptError) { // i.e. osatest/TestLib bug
        logScriptError(ci, [NSString stringWithFormat: @"Failed to perform %@'s %@.", suiteName, handlerName]);
    } else if (err != noErr) { // i.e. TestLib bug
        logErr(@"OSADoEvent error: %i\n\n", err); // e.g. -1708 = event not handled
    }
    OSADispose(ci, scriptID);
    return err;
}


OSAError logTestReport(ComponentInstance ci, OSAID scriptID, int lineWidth, int *testStatus) { // tell the TestReport script object returned by invokeTestLib to generate finished test report text
    OSAError err = noErr;
    // TO DO: call report handlers to convert text data to text, then to obtain completed report
    while (1) { // breaks when TestReport's nextrawdata iterator is exhausted (i.e. returns error 6502)
    // build AppleEvent to invoke TestReport's nextrawdata handler, returning an AS value ID to format as AS literal
        NSAppleEventDescriptor *getRawEvent = newSubroutineEvent(@"nextrawdata", AEEMPTYLIST);
        OSAID valueID;
        err = OSAExecuteEvent(ci, getRawEvent.aeDesc, scriptID, 0, &valueID);
        if (err != noErr) {
            if (err == errOSAScriptError) { // i.e. osatest/TestLib bug
                if (scriptErrorNumber(ci) == 6502) {
                    break; // exit loop
                } else {
                    logScriptError(ci, @"Failed to get next raw value.");
                }
            } else if (err != noErr) { // i.e. TestLib bug, e.g. -1708 = event not handled = incorrect handler name
                logErr(@"Failed to get next raw value (error: %i).\n", err);
            }
            return err;
        }
        AEDesc literalValueDesc;
        err = OSADisplay(ci, valueID, typeUnicodeText, 0, &literalValueDesc);
        OSADispose(ci, valueID);
        if (err != noErr) {
            logErr(@"Failed to format raw value (error: %i).\n", err);
            return err;
        }
        NSAppleEventDescriptor *params = AEEMPTYLIST;
        [params insertDescriptor: AEWRAP(&literalValueDesc) atIndex: 0];
        NSAppleEventDescriptor *replyEvent = nil;
        err = callSubroutine(ci, scriptID, @"updaterawdata", params, &replyEvent);
        if (err != noErr) { // bug in TestReport's updaterawdata handler
            logErr(@"Failed to update raw value. %@\n", AEERRORMESSAGE(replyEvent));
            return err;
        }
    }
    NSAppleEventDescriptor *replyEvent = nil;
    err = callSubroutine(ci, scriptID, @"renderreport", AEEMPTYLIST, &replyEvent);
    if (err != noErr) { // bug in TestReport's renderreport handler
        logErr(@"Report generation failed. %@\n", AEERRORMESSAGE(replyEvent));
        return err;
    }
    NSAppleEventDescriptor *reportRecord = AERESULT(replyEvent, typeAERecord);
    *testStatus = [reportRecord descriptorForKeyword: 'Stat'].int32Value;
    // TO DO: direct object needs to be list/record of two (or more?) fields: {statusFlag, reportText}
    NSString *report = [reportRecord descriptorForKeyword: 'Repo'].stringValue;
    if (report == nil) {
        logErr(@"Missing report.");
        return 1;
    }
    logOut(@"%@\n", report);
    return noErr;
}

//

OSAError runOneTest(OSALanguage *language, AEDesc scriptData, NSURL *scriptURL,
                    NSString *suiteName, NSString *handlerName, int lineWidth, int *status) {
    @autoreleasepool {
        OSALanguageInstance *li = [OSALanguageInstance languageInstanceWithLanguage: language];
        OSAID scriptID, reportScriptID = 0;
        OSAError err = OSALoadScriptData(li.componentInstance, &scriptData, (__bridge CFURLRef)(scriptURL), 0, &scriptID);
        if (err != noErr) return err; // (shouldn't fail as script's already been successfully loaded once)
        err = invokeTestLib(li.componentInstance, scriptID, suiteName, handlerName, lineWidth, &reportScriptID);
        if (err == noErr) err = logTestReport(li.componentInstance, reportScriptID, lineWidth, status);
        if (err != noErr) logErr(@"Failed to generate report (error %i)", err); // i.e. TestLib bug
        OSADispose(li.componentInstance, reportScriptID);
        return err;
    }
}


/******************************************************************************/


int terminalColumns(void) {
    int width = -1;
    struct winsize ws;
    int fd = open("/dev/tty", O_RDWR);
    if (fd < 0) return -1;
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0) width = (int)ws.ws_col;
    close(fd);
    return width;
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
            logErr(@"Failed to read script (error %i).\n", err);
            FAILRETURN;
        }
        err = OSALoadScriptData(languageInstance.componentInstance, &scriptDesc, (__bridge CFURLRef)(scriptURL), 0, &scriptID);
        if (err != noErr) {
            logErr(@"Failed to load script (error %i).\n", err);
            FAILRETURN;
        }
        NSArray<NSString *> *suiteNames = suiteNamesForScript(languageInstance.componentInstance, scriptID);
        if (suiteNames == nil) {
            logErr(@"Failed to get suite names.\n");
            FAILRETURN;
        }
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
                int status = 0; // -1 = TestLib failed (bug)
                err = runOneTest(language, scriptDesc, scriptURL, suiteName, handlerName, lineWidth, &status);
                if (err != noErr) FAILRETURN;
                if (status == _SKIPSUITE) { // break out of runOneTest loop
                    statusCounts.skipped++; // note: this doesn't distinguish between skipped tests and skipped suites; it's just to provide reminder in final result line that *something* got skipped
                    handlerNames = nil;
                    break;
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
                    case _SKIPPED:
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
        logOut(@"%@Result: %i passed, %i failed, %i broken, %i skipped.%@\n\n",
               (lineWidth == -1 ? @"" : (statusCounts.failure == 0 && statusCounts.broken == 0 ? VTPASSED : VTFAILED)),
               statusCounts.success, statusCounts.failure, statusCounts.broken, statusCounts.skipped,
               (lineWidth == -1 ? @"" : VTNORMAL));
        return 0;
    }
}



int main(int argc, const char * argv[]) {
    if (argc < 2 || strcmp(argv[1], "-h") == 0) {
        printf("Usage: osatest FILE ...\n");
//        return runTestFile([NSURL fileURLWithPath: @"~/Library/Script Libraries/unittests/textlib.unittest.scpt".stringByStandardizingPath]); // TEST; TO DO: delete
        return 0;
    }
    for (int i = 1; i < argc; i++) {
        NSURL *scriptURL = [NSURL fileURLWithFileSystemRepresentation:argv[i] isDirectory: NO relativeToURL: nil];
        if (scriptURL == nil) return fnfErr;
        int err = runTestFile(scriptURL);
        if (err != noErr) return err;
    }
}

