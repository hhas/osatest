//
//  main.m
//  osatest
//
//  OSAScript doesn't expose scriptID, so is utterly useless if OpenScripting-only APIs need to be used
//
//  note: deprecation warnings are off


#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>
#import <OSAKit/OSAKit.h>


#define AEWRAP(aedesc) ([[NSAppleEventDescriptor alloc] initWithAEDescNoCopy: (aedesc)])
#define AESTRING(nsString) ([NSAppleEventDescriptor descriptorWithString: (nsString)])


void LogAEDesc(char *labelCStr, AEDesc *aeDescPtr) { // debug
    Handle h;
    AEPrintDescToHandle((aeDescPtr), &h);
    printf("%s%s\n", (labelCStr), *h);
    DisposeHandle(h); // TO DO: disable deprecation warning
}


///////


NSArray<NSString *> *SuiteNamesForScript(ComponentInstance ci, OSAID scriptID) {
    AEDescList resultingNames;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (OSAGetPropertyNames(ci, 0, scriptID, &resultingNames) != noErr) return nil;
//    LogAEDesc("", &resultingNames);
    NSAppleEventDescriptor *namesDesc = AEWRAP(&resultingNames);
    for (NSInteger i = 1; i <= namesDesc.numberOfItems; i++) {
        NSString *name = [namesDesc descriptorAtIndex: i].stringValue; // may be nil
        if ([name.lowercaseString hasPrefix: @"suite_"] && name.length > 6) [names addObject: name];
    }
    return names.copy;
}



NSArray<NSString *> *TestNamesForSuiteName(ComponentInstance ci, OSAID scriptID,
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


///////


NSAppleEventDescriptor *BuildObjectSpecifier(OSType wantCode,
                                             OSType selectorType, NSAppleEventDescriptor *selectorData,
                                             NSAppleEventDescriptor *containerDesc) {
    NSAppleEventDescriptor *desc = [[NSAppleEventDescriptor recordDescriptor] coerceToDescriptorType: typeObjectSpecifier];
    [desc setDescriptor: [NSAppleEventDescriptor descriptorWithTypeCode: wantCode] forKeyword: keyAEDesiredClass];
    [desc setDescriptor: [NSAppleEventDescriptor descriptorWithEnumCode: selectorType] forKeyword: keyAEKeyForm];
    [desc setDescriptor: selectorData forKeyword: keyAEKeyData];
    [desc setDescriptor: (containerDesc ?: [NSAppleEventDescriptor nullDescriptor]) forKeyword: keyAEContainer];
    return desc;
}

///////


int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc != 2) {
  //          printf("Usage: osatest FILE\n");
  //          return 0;
        }
  //      NSURL *scriptURL = [NSURL fileURLWithFileSystemRepresentation:argv[1] isDirectory: NO relativeToURL: nil];
        NSURL *scriptURL = [NSURL fileURLWithPath: @"/Users/has/Library/Script Libraries/textlib.unittest.scpt"]; // TEST; TO DO: delete
        
        BOOL useVT100Styles = YES; // TO DO: determine if stdout is connected to terminal, and apply VT100 styles
        
        OSALanguage *language = [OSALanguage languageForName: @"AppleScript"];
        OSALanguageInstance *languageInstance = [OSALanguageInstance languageInstanceWithLanguage: language];
        AEDesc scriptData;
        OSAError err = OSAGetScriptDataFromURL((__bridge CFURLRef)(scriptURL), 0, 0, &scriptData);
        if (err != noErr) return err;
        OSAID scriptID;
        err = OSALoadScriptData(languageInstance.componentInstance, &scriptData, (__bridge CFURLRef)(scriptURL), 0, &scriptID);
        if (err != noErr) return err;
        NSArray<NSString *> *suiteNames = SuiteNamesForScript(languageInstance.componentInstance, scriptID);
        if (suiteNames == nil) {
            printf("Can’t get suite names.\n");
            return 1;
        }
        for (NSString *suiteName in suiteNames) {
            CFShow((__bridge CFTypeRef)(suiteName));
            NSAppleEventDescriptor *allHandlerNamesDesc;
            NSArray<NSString *> *handlerNames = TestNamesForSuiteName(languageInstance.componentInstance, scriptID,
                                                                      suiteName, &allHandlerNamesDesc);
            for (NSString *handlerName in handlerNames) {
                // run a single test
                
                CFShow((__bridge CFTypeRef)([NSString stringWithFormat: @"  %@", handlerName]));
                NSAppleEventDescriptor *suiteNameDesc = [NSAppleEventDescriptor descriptorWithString: suiteName];
                NSAppleEventDescriptor *handlerNameDesc = [NSAppleEventDescriptor descriptorWithString: handlerName];
                
                
                NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass: '#@[:'
                                                                                         eventID: '>>!!'
                                                                                targetDescriptor: nil
                                                                                        returnID: kAutoGenerateReturnID
                                                                                   transactionID:kAnyTransactionID];
                
                
                NSAppleEventDescriptor *targetDesc = BuildObjectSpecifier(cProperty, formUserPropertyID, suiteNameDesc, nil);
                
                [event setAttributeDescriptor:  targetDesc  forKeyword: keySubjectAttr];
    //            [event setParamDescriptor: targetDesc forKeyword: keyDirectObject];
                [event setParamDescriptor: suiteNameDesc forKeyword: 'SuNa'];
                [event setParamDescriptor: handlerNameDesc forKeyword: 'HaNa'];
                [event setParamDescriptor: allHandlerNamesDesc forKeyword: 'AHaN'];
                [event setParamDescriptor: [NSAppleEventDescriptor descriptorWithBoolean: useVT100Styles] forKeyword: 'VFmt'];
                
                
           /*
                event = [NSAppleEventDescriptor appleEventWithEventClass: 'core'
                                                                 eventID: 'getd'
                                                        targetDescriptor: nil
                                                                returnID: kAutoGenerateReturnID
                                                           transactionID:kAnyTransactionID];
            
                [event setParamDescriptor: targetDesc forKeyword: keyDirectObject];
                [event setAttributeDescriptor: [NSAppleEventDescriptor nullDescriptor] forKeyword: keySubjectAttr];
            
            
                
        //      [event setParamDescriptor: BuildObjectSpecifier(cProperty, formUserPropertyID, [NSAppleEventDescriptor descriptorWithString: @"x"], nil) forKeyword: '----'];

        //      [event setParamDescriptor: BuildObjectSpecifier(cProperty, formUserPropertyID, [NSAppleEventDescriptor descriptorWithString: @"x"], BuildObjectSpecifier(cProperty, formUserPropertyID, suiteNameDesc, nil)) forKeyword: '----'];
            */

                
                // important: each test must run in its own CI to avoid sharing TIDs, library instances, etc with other tests
                OSALanguageInstance *testInstance = [OSALanguageInstance languageInstanceWithLanguage: language];
                OSAID testScriptID;
                err = OSALoadScriptData(testInstance.componentInstance, &scriptData,
                                        (__bridge CFURLRef)(scriptURL), kOSAModeCompileIntoContext, &testScriptID);
                if (err != noErr) return err;
                
                
                
                CFAttributedStringRef src;
                OSACopyDisplayString(testInstance.componentInstance, testScriptID, 0, &src);
                CFShow(CFAttributedStringGetString(src));
                
                
                //NSLog(@"\n%@\n\n", SuiteNamesForScript(testInstance.componentInstance, testScriptID));
                
                printf("\n\n");
                
                NSLog(@"%@",event);
                
                AppleEvent replyEvent;
                err = AECreateAppleEvent('aevt', 'repl', [NSAppleEventDescriptor nullDescriptor].aeDesc, kAutoGenerateReturnID, kAnyTransactionID, &replyEvent);
                if (err != noErr) return err;
                err = OSADoEvent(testInstance.componentInstance, event.aeDesc, testScriptID, 0, &replyEvent);
                
                if (err != noErr) {
                    printf("OSADoEvent error: %i\n\n", err); // OSADoEvent throws -1708 (event not handled)
                } else {
                    LogAEDesc("Reply Event", &replyEvent);
                }
                
                /*
                OSAID testReportScriptID;
                err = OSAExecuteEvent(testInstance.componentInstance, event.aeDesc, testScriptID, 0, &testReportScriptID);
                if (err != noErr) {
                    AEDesc errorInfo;
                    if (OSAScriptError(testInstance.componentInstance, kOSAErrorNumber, typeSInt32, &errorInfo) == noErr) {
                        LogAEDesc("errno:", &errorInfo);
                        AEDisposeDesc(&errorInfo);
                    }
                    if (OSAScriptError(testInstance.componentInstance, kOSAErrorMessage, typeUnicodeText, &errorInfo) == noErr) {
                        LogAEDesc("errno:", &errorInfo);
                        AEDisposeDesc(&errorInfo);
                    }
                    
                    printf("`do unit test handler` failed\n"); // TO DO: get full error info from CI
                    return err;
                }
                */
                // for each "trap_", fab a script object? or just use AE to invoke?
                return err;
            }
        }
    }
    return 0;
}


