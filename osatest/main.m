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
//  TO DO: would probably be safer if TestLib handlers called by osatest use AE event class and ID codes rather than AS identifiers, as the latter are prone to case changes


#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>


#define AEWRAP(aedesc) ([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy: (aedesc)])
#define AESTRING(nsString) ([NSAppleEventDescriptor descriptorWithString: (nsString)])
#define AEBOOL(nsBool) ([NSAppleEventDescriptor descriptorWithBoolean: (nsBool)])

#define VTNORMAL    "\x1b[0m"
#define VTBOLD      "\x1b[1m"
#define VTUNDER     "\x1b[4m"
#define VTRED       "\x1b[31m"
#define VTGREEN     "\x1b[32m"
#define VTBLUE      "\x1b[34m"


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
                       NSString *suiteName, NSString *handlerName, BOOL useVT100Styles, OSAID *reportScriptID) {
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
                                           allHandlerNamesDesc, AEBOOL(useVT100Styles)]) {
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


OSAError logTestReport(ComponentInstance ci, OSAID scriptID, BOOL useVT100Styles) { // tell the TestReport script object returned by invokeTestLib to generate finished test report text
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
    // TO DO: direct object needs to be list/record of two (or more?) fields: {statusFlag, reportText}
    logOut(@"%@\n", [replyEvent paramDescriptorForKeyword: keyDirectObject].stringValue);
    return noErr;
}

//

OSAError performTest(OSALanguage *language, AEDesc scriptData, NSURL *scriptURL,
                     NSAppleEventDescriptor *allHandlerNamesDesc,
                     NSString *suiteName, NSString *handlerName, BOOL useVT100Styles) {
    @autoreleasepool {
        OSALanguageInstance *li = [OSALanguageInstance languageInstanceWithLanguage: language];
        OSAID scriptID, reportScriptID = 0;
        OSAError err = OSALoadScriptData(li.componentInstance, &scriptData, (__bridge CFURLRef)(scriptURL), 0, &scriptID);
        if (err != noErr) return err; // (shouldn't fail as script's already been successfully loaded once)
        err = invokeTestLib(li.componentInstance, scriptID, allHandlerNamesDesc,
                            suiteName, handlerName, useVT100Styles, &reportScriptID);
        if (err == noErr) err = logTestReport(li.componentInstance, reportScriptID, useVT100Styles);
        if (err != noErr) fprintf(stderr, "Failed to generate report (error %i)", err); // i.e. TestLib bug
        OSADispose(li.componentInstance, reportScriptID);
        return err;
    }
}


/******************************************************************************/
// main


int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc != 2) {
  //          printf("Usage: osatest FILE\n");
  //          return 0;
        }
  //      NSURL *scriptURL = [NSURL fileURLWithFileSystemRepresentation:argv[1] isDirectory: NO relativeToURL: nil];
        NSURL *scriptURL = [NSURL fileURLWithPath: @"~/Library/Script Libraries/textlib.unittest.scpt".stringByStandardizingPath]; // TEST; TO DO: delete
        
        BOOL useVT100Styles = NO; // TO DO: determine if stdout is connected to terminal, and apply VT100 styles
        
        NSDate *startTime = [NSDate date];
        logOut(@"Load %@\nBegin tests at %@\n", scriptURL.path, startTime);
        
        // introspect the unittest.scpt, getting names of all top-level script objects named `suite_NAME`
        // (note: this could quite easily be made recursive, allowing users to group suites into sub-suites if they wish, but for now just go with simple flat `suite>test` hierarchy and see how well that works in practice)
        OSALanguage *language = [OSALanguage languageForName: @"AppleScript"];
        OSALanguageInstance *languageInstance = [OSALanguageInstance languageInstanceWithLanguage: language];
        AEDesc scriptData;
        OSAError err = OSAGetScriptDataFromURL((__bridge CFURLRef)(scriptURL), 0, 0, &scriptData);
        if (err != noErr) return err;
        OSAID scriptID;
        err = OSALoadScriptData(languageInstance.componentInstance, &scriptData, (__bridge CFURLRef)(scriptURL), 0, &scriptID);
        if (err != noErr) {
            logErr(@"Failed to load script (error %i): %@\n", err, scriptURL.path);
            return err;
        }
        NSArray<NSString *> *suiteNames = suiteNamesForScript(languageInstance.componentInstance, scriptID);
        if (suiteNames == nil) {
            fprintf(stderr, "Can’t get suite names.\n");
            return 1;
        }
        // run the unit tests
        // important: each test must run in its own CI to avoid sharing TIDs, library instances, etc with other tests
        NSInteger suiteIndex = 0, testIndex = 0;
        for (NSString *suiteName in suiteNames) {
            ++suiteIndex;
            NSAppleEventDescriptor *allHandlerNamesDesc;
            NSArray<NSString *> *handlerNames = testNamesForSuiteName(languageInstance.componentInstance, scriptID,
                                                                      suiteName, &allHandlerNamesDesc);
            if ([handlerNames containsObject: @"skipTests"]) { // if found, call skipTests handler to get names of tests to ignore as record of form {test_NAME:reasonText,...}
            }
            for (NSString *handlerName in handlerNames) {
                logOut(@"%i.%i  %@'s %@: ", suiteIndex, ++testIndex,
                       [suiteName substringFromIndex:6], [handlerName substringFromIndex:5]);
                err = performTest(language, scriptData, scriptURL,
                                  allHandlerNamesDesc, suiteName, handlerName, useVT100Styles);
                if (err != noErr) logOut(@"Aborted suite (error %i): %@\n", err, suiteName);
            }
        }
        NSDate *endedTime = [NSDate date];
        logOut(@"Ended tests at %@ (%0.3fs)\n", endedTime, [endedTime timeIntervalSinceDate: startTime]);
        // TO DO: final tally of pass/fail/broke
    }
    return 0;
}


