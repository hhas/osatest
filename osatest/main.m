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


#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>

#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>


#define AEWRAP(aedesc) ([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy: (aedesc)])
#define AESTRING(nsString) ([NSAppleEventDescriptor descriptorWithString: (nsString)])
#define AEINT(n) ([NSAppleEventDescriptor descriptorWithInt32: (n)])
#define AEBOOL(nsBool) ([NSAppleEventDescriptor descriptorWithBoolean: (nsBool)])

#define VTNORMAL    @"\x1b[0m"
#define VTBOLD      @"\x1b[1m"
#define VTUNDER     @"\x1b[4m"
#define VTRED       @"\x1b[31m"
#define VTGREEN     @"\x1b[32m"
#define VTBLUE      @"\x1b[34m"

#define VTHEADING   (VTBOLD VTUNDER)
#define VTPASSED    (VTGREEN)
#define VTFAILED    (VTRED)

// constants defined by TestLib's TestSupport sub-library
#define _BUG     (0)
#define _SUCCESS (1)
#define _FAILURE (2)
#define _BROKEN  (3)
#define _SKIPPED (4)

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

NSArray<NSString *> *suiteNamesForScript(ComponentInstance ci, OSAID scriptID) {
    AEDescList resultingNames;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (OSAGetPropertyNames(ci, 0, scriptID, &resultingNames) != noErr) return nil;
//    logAEDesc("", &resultingNames);
    NSAppleEventDescriptor *namesDesc = AEWRAP(&resultingNames);
    for (NSInteger i = 1; i <= namesDesc.numberOfItems; i++) {
        NSString *name = [namesDesc descriptorAtIndex: i].stringValue; // may be nil
        if ([name.lowercaseString hasPrefix: @"suite_"] && name.length > 6) [names addObject: name];
    }
    return names.copy;
}


NSArray<NSString *> *testNamesForSuiteName(ComponentInstance ci, OSAID scriptID,
                                           NSString *suiteName, NSAppleEventDescriptor **allHandlerNamesDesc) {
    OSAID scriptValueID;
    if (OSAGetProperty(ci, 0, scriptID, AESTRING(suiteName).aeDesc, &scriptValueID) != noErr) return nil;
    // TO DO: check scriptValueID is actually typeScript? or is OSAGetHandlerNames guaranteed to fail if it isn't?
    AEDescList resultingNames;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (OSAGetHandlerNames(ci, 0, scriptValueID, &resultingNames) != noErr) {
        OSADispose(ci, scriptValueID);
        return nil;
    }
    *allHandlerNamesDesc = AEWRAP(&resultingNames);
    for (NSInteger i = 1; i <= (*allHandlerNamesDesc).numberOfItems; i++) {
        NSString *name = [*allHandlerNamesDesc descriptorAtIndex: i].stringValue; // may be nil
        NSString *key = name.lowercaseString;
        if (([key hasPrefix: @"test_"] && name.length > 5) || ([key hasPrefix: @"trap_"] && name.length > 5)) [names addObject: name]; // TO DO: use trap_NAME to verify assertError() specifies valid handler name
    }
    OSADispose(ci, scriptValueID);
    return names.copy;
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


OSAError doSubroutine(ComponentInstance ci, OSAID scriptID, NSString *handlerName,
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
OSAError invokeTestLib(ComponentInstance ci, OSAID scriptID, NSAppleEventDescriptor *allHandlerNamesDesc,
                       NSString *suiteName, NSString *handlerName, int lineWrap, OSAID *reportScriptID) {
    // add a new code-generated __performunittest__ handler to test script
    NSString *code = [NSString stringWithFormat:
                      @"to __performunittest__(|params|)\n"
                      @"return script \"TestLib\"'s __performunittestforsuite__(my (%@), (|params|))\n"
                      @"end __performunittest__", sanitizeIdentifier(suiteName)];
    OSAError err = OSACompile(ci, AESTRING(code).aeDesc, kOSAModeAugmentContext, &scriptID);
    if (err != noErr) {
        fprintf(stderr, "Failed to add __performunittest__\n");
        OSADispose(ci, scriptID);
        return err;
    }
    // build AppleEvent to invoke the __performunittest__ handler
    NSAppleEventDescriptor *testData = [NSAppleEventDescriptor listDescriptor];
    for (NSAppleEventDescriptor *item in @[AESTRING(suiteName), AESTRING(handlerName),
                                           allHandlerNamesDesc, AEINT(lineWrap)]) {
        [testData insertDescriptor: item atIndex: 0];
    }
    NSAppleEventDescriptor *params = [NSAppleEventDescriptor listDescriptor];
    [params insertDescriptor: testData atIndex: 0];
    NSAppleEventDescriptor *event = newSubroutineEvent(@"__performunittest__", params);
    // call test script's code-generated __performunittest__ handler passing test data;
    // it then calls TestLib's __performunittestforsuite__ with the `suite_NAME` object and test data
    // __performunittestforsuite__ should always return a TestReport object, which appears as a new scriptID
    err = OSAExecuteEvent(ci, event.aeDesc, scriptID, 0, reportScriptID);
    if (err == errOSAScriptError) { // i.e. osatest/TestLib bug
        logScriptError(ci, [NSString stringWithFormat: @"Failed to perform %@'s %@.", suiteName, handlerName]);
    } else if (err != noErr) { // i.e. TestLib bug
        fprintf(stderr, "OSADoEvent error: %i\n\n", err); // e.g. -1708 = event not handled
    }
    OSADispose(ci, scriptID);
    return err;
}


OSAError logTestReport(ComponentInstance ci, OSAID scriptID, int lineWrap, int *testStatus) { // tell the TestReport script object returned by invokeTestLib to generate finished test report text
    OSAError err = noErr;
    // TO DO: call report handlers to convert text data to text, then to obtain completed report
    while (1) { // breaks when TestReport's nextrawdata iterator is exhausted (i.e. returns error 6502)
    // build AppleEvent to invoke TestReport's nextrawdata handler, returning an AS value ID to format as AS literal
        NSAppleEventDescriptor *getRawEvent = newSubroutineEvent(@"nextrawdata", [NSAppleEventDescriptor listDescriptor]);
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
                fprintf(stderr, "Failed to get next raw value (error: %i).\n", err);
            }
            return err;
        }
        AEDesc literalValueDesc;
        err = OSADisplay(ci, valueID, typeUnicodeText, 0, &literalValueDesc);
        OSADispose(ci, valueID);
        if (err != noErr) {
            fprintf(stderr, "Failed to format raw value.\n");
            return err;
        }
        NSAppleEventDescriptor *params = [NSAppleEventDescriptor listDescriptor];
        [params insertDescriptor: AEWRAP(&literalValueDesc) atIndex: 0];
        NSAppleEventDescriptor *replyEvent = nil;
        err = doSubroutine(ci, scriptID, @"updaterawdata", params, &replyEvent);
        if (err == noErr) { // bug in TestReport's updaterawdata handler
            err = [replyEvent paramDescriptorForKeyword: keyErrorNumber].int32Value;
        }
        if (err != noErr) {
            fprintf(stderr, "Failed to update raw value.\n");
            return err;
        }
    }
    NSAppleEventDescriptor *replyEvent = nil;
    err = doSubroutine(ci, scriptID, @"renderreport", [NSAppleEventDescriptor listDescriptor], &replyEvent);
    if (err == noErr) {
        err = [replyEvent paramDescriptorForKeyword: keyErrorNumber].int32Value;
    }
    if (err != noErr) { // bug in TestReport's renderreport handler
        logErr(@"Report generation failed. %@\n", [replyEvent paramDescriptorForKeyword: keyErrorString].stringValue);
        return err;
    }
    NSAppleEventDescriptor *reportRecord = [[replyEvent paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType:typeAERecord];
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

OSAError performTest(OSALanguage *language, AEDesc scriptData, NSURL *scriptURL,
                     NSAppleEventDescriptor *allHandlerNamesDesc,
                     NSString *suiteName, NSString *handlerName, int lineWrap, int *status) {
    @autoreleasepool {
        OSALanguageInstance *li = [OSALanguageInstance languageInstanceWithLanguage: language];
        OSAID scriptID, reportScriptID = 0;
        OSAError err = OSALoadScriptData(li.componentInstance, &scriptData, (__bridge CFURLRef)(scriptURL), 0, &scriptID);
        if (err != noErr) return err; // (shouldn't fail as script's already been successfully loaded once)
        err = invokeTestLib(li.componentInstance, scriptID, allHandlerNamesDesc,
                            suiteName, handlerName, lineWrap, &reportScriptID);
        if (err == noErr) err = logTestReport(li.componentInstance, reportScriptID, lineWrap, status);
        if (err != noErr) fprintf(stderr, "Failed to generate report (error %i)", err); // i.e. TestLib bug
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
        int lineWrap = terminalColumns(); // if stdout is connected to terminal returns column width, else returns -1
        logOut(@"%@osatest '%@'%@\n",
               (lineWrap == -1 ? @"" : VTHEADING),
               [scriptURL.path stringByReplacingOccurrencesOfString: @"'" withString:@"'\\''"],
               (lineWrap == -1 ? @"" : VTNORMAL));
        // introspect the unittest.scpt, getting names of all top-level script objects named `suite_NAME`
        // (note: this could quite easily be made recursive, allowing users to group suites into sub-suites if they wish, but for now just go with simple flat `suite>test` hierarchy and see how well that works in practice)
        OSALanguage *language = [OSALanguage languageForName: @"AppleScript"];
        OSALanguageInstance *languageInstance = [OSALanguageInstance languageInstanceWithLanguage: language];
        AEDesc scriptData;
        OSAError err = OSAGetScriptDataFromURL((__bridge CFURLRef)(scriptURL), 0, 0, &scriptData);
        if (err != noErr) {
            logErr(@"Failed to read script (error %i).\n");
            return err;
        }
        OSAID scriptID;
        err = OSALoadScriptData(languageInstance.componentInstance, &scriptData, (__bridge CFURLRef)(scriptURL), 0, &scriptID);
        if (err != noErr) {
            logErr(@"Failed to load script (error %i).\n", err);
            return err;
        }
        NSArray<NSString *> *suiteNames = suiteNamesForScript(languageInstance.componentInstance, scriptID);
        if (suiteNames == nil) {
            logErr(@"Can’t get suite names.\n");
            return 1;
        }
        // TO DO: check for a top-level "skipSuites" handler containing record of form {suite_NAME:reasonText,...}; if found, skip and log accordingly (simplest is to call OSAGetHandler to confirm existence, then send event if found [i.e. don't want to blindly send AE as there's no way to tell if -1708 error is due to handler not existing or handler containing a bug])
        // run the unit tests
        // important: each test must run in its own CI to avoid sharing TIDs, library instances, etc with other tests
        NSString *testTitleTemplate = lineWrap == -1 ? @"%i.%i %@'s %@: " : @"\x1b[1m%i.%i %@'s %@\x1b[0m: ";
        StatusCounts statusCounts = {0,0,0,0,0};
        NSInteger suiteIndex = 0;
        NSDate *startTime = [NSDate date];
        logOut(@"Begin tests at %@\n", startTime);
        for (NSString *suiteName in suiteNames) {
            ++suiteIndex;
            NSAppleEventDescriptor *allHandlerNamesDesc;
            NSArray<NSString *> *handlerNames = testNamesForSuiteName(languageInstance.componentInstance, scriptID,
                                                                      suiteName, &allHandlerNamesDesc);
            if ([handlerNames containsObject: @"skipTests"]) { // if found, call skipTests handler to get names of tests to ignore as record of form {test_NAME:reasonText,...}
            }
            NSString *suiteTitle = [suiteName substringFromIndex:6];
            NSInteger testIndex = 0;
            for (NSString *handlerName in handlerNames) {
                logOut(testTitleTemplate, suiteIndex, ++testIndex, suiteTitle, [handlerName substringFromIndex:5]);
                int status = 0; // -1 = TestLib failed (bug)
                err = performTest(language, scriptData, scriptURL,
                                  allHandlerNamesDesc, suiteName, handlerName, lineWrap, &status);
                if (err != noErr) logOut(@"  Aborted test due to bug (error %i).\n", err);
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
                        logErr(@"Exiting due to bug or invalid test status: %i", status);
                        return 1;
                }
            }
        }
        NSDate *endedTime = [NSDate date];
        logOut(@"Ended tests at %@ (%0.3fs)\n", endedTime, [endedTime timeIntervalSinceDate: startTime]);
        logOut(@"%@%@Result: %i passed, %i failed, %i broken, %i skipped.%@\n\n",
               (statusCounts.failure == 0 && statusCounts.broken == 0 ? VTPASSED : VTFAILED),
               (lineWrap == -1 ? @"" : VTBOLD),
               statusCounts.success, statusCounts.failure, statusCounts.broken, statusCounts.skipped,
               (lineWrap == -1 ? @"" : VTNORMAL));
    }
    return 0;
}



int main(int argc, const char * argv[]) {
    if (argc < 2 || strcmp(argv[1], "-h") == 0) {
        printf("Usage: osatest FILE ...\n"); // TO DO: re-enable
//        return runTestFile([NSURL fileURLWithPath: @"~/Library/Script Libraries/textlib.unittest.scpt".stringByStandardizingPath]); // TEST; TO DO: delete
        return 0;
    }
    for (int i = 1; i < argc; i++) {
        NSURL *scriptURL = [NSURL fileURLWithFileSystemRepresentation:argv[i] isDirectory: NO relativeToURL: nil];
        if (scriptURL == nil) return fnfErr;
        int err = runTestFile(scriptURL);
        if (err != noErr) return err;
    }
}

