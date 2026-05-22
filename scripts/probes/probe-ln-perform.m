//
// probe-ln-perform.m
//
// Construct an LNAction for ChatKit.OpenMessageIntent and try to execute it.
// Pure Objective-C — easier than Swift's @convention(c) bridging gymnastics.
//
// Build:
//   clang -framework AppKit -framework Foundation -ObjC probe-ln-perform.m -o probe-ln-perform
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *chatIdentifier(NSString *guid) {
    NSArray<NSString *> *parts = [guid componentsSeparatedByString:@";"];
    return parts.count == 3 ? parts[2] : guid;
}

int main(int argc, const char * argv[]) {
    if (argc < 3) {
        printf("usage: probe-ln-perform <chatGUID> <messageGUID>\n");
        return 2;
    }
    NSString *chatGUID = @(argv[1]);
    NSString *messageGUID = @(argv[2]);
    NSString *chatID = chatIdentifier(chatGUID);
    printf("chatGUID    = %s\n", [chatGUID UTF8String]);
    printf("messageGUID = %s\n", [messageGUID UTF8String]);
    printf("chatID      = %s\n", [chatID UTF8String]);

    void *h = dlopen("/System/Library/Frameworks/AppIntents.framework/AppIntents", RTLD_NOW);
    if (!h) { printf("FATAL: %s\n", dlerror()); return 1; }

    Class LNEntityIDClass     = NSClassFromString(@"LNEntityIdentifier");
    Class LNEntityClass       = NSClassFromString(@"LNEntity");
    Class LNValueClass        = NSClassFromString(@"LNValue");
    Class LNParameterClass    = NSClassFromString(@"LNParameter");
    Class LNActionClass       = NSClassFromString(@"LNAction");
    Class LNEntityValueType   = NSClassFromString(@"LNEntityValueType");

    if (!LNEntityIDClass || !LNEntityClass || !LNValueClass || !LNParameterClass || !LNActionClass || !LNEntityValueType) {
        printf("FATAL: missing one of the LN classes\n");
        return 1;
    }

    // 1) LNEntityIdentifier(value: messageGUID, typeName: "MessageEntity")
    id entityID = [[LNEntityIDClass alloc] performSelector:@selector(initWithValue:typeName:)
                                                withObject:messageGUID
                                                withObject:@"MessageEntity"];
    printf("entityID = %s\n", [[entityID description] UTF8String]);

    // 2) LNEntity(identifier: entityID)
    id entity = [[LNEntityClass alloc] performSelector:@selector(initWithIdentifier:) withObject:entityID];
    printf("entity   = %s\n", [[entity description] UTF8String]);

    // 3) LNEntityValueType(typeName: "MessageEntity")
    id entityType = [[LNEntityValueType alloc] performSelector:@selector(initWithTypeName:)
                                                    withObject:@"MessageEntity"];
    printf("entityType = %s\n", [[entityType description] UTF8String]);

    // 4) LNValue(value: entity, valueType: entityType)
    id lnValue = [[LNValueClass alloc] performSelector:@selector(initWithValue:valueType:)
                                            withObject:entity
                                            withObject:entityType];
    printf("lnValue    = %s\n", [[lnValue description] UTF8String]);

    // 5) LNParameter(identifier: "target", value: lnValue)
    id parameter = [[LNParameterClass alloc] performSelector:@selector(initWithIdentifier:value:)
                                                  withObject:@"target"
                                                  withObject:lnValue];
    printf("parameter  = %s\n", [[parameter description] UTF8String]);

    // 6) LNAction(identifier:"OpenMessageIntent", mangledTypeName:"7ChatKit17OpenMessageIntentV", openAppWhenRun: YES, parameters: [parameter])
    // 4-arg init — performSelector only supports 2. Use NSInvocation.
    SEL actionSel = @selector(initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:);
    NSMethodSignature *sig = [LNActionClass instanceMethodSignatureForSelector:actionSel];
    if (!sig) { printf("FATAL: no signature for LNAction init\n"); return 1; }
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = [LNActionClass alloc];
    inv.selector = actionSel;
    NSString *intentID = @"OpenMessageIntent";
    NSString *mangled = @"7ChatKit17OpenMessageIntentV";
    BOOL openWhenRun = YES;
    NSArray *params = @[parameter];
    [inv setArgument:&intentID atIndex:2];
    [inv setArgument:&mangled atIndex:3];
    [inv setArgument:&openWhenRun atIndex:4];
    [inv setArgument:&params atIndex:5];
    [inv invoke];

    void *retainedAction = NULL;
    [inv getReturnValue:&retainedAction];
    id action = (__bridge id)retainedAction;
    printf("action     = %s\n", [[action description] UTF8String]);

    if (!action) {
        printf("FATAL: action is nil\n");
        return 1;
    }

    printf("\nLNAction properties:\n");
    printf("  identifier:      %s\n", [[action valueForKey:@"identifier"] UTF8String] ?: "(null)");
    printf("  mangledTypeName: %s\n", [[action valueForKey:@"mangledTypeName"] UTF8String] ?: "(null)");
    printf("  openAppWhenRun:  %s\n", [[[action valueForKey:@"openAppWhenRun"] stringValue] UTF8String] ?: "(null)");
    id url = [action valueForKey:@"url"];
    printf("  url:             %s\n", url ? [[url description] UTF8String] : "(null)");

    // Try opening the URL via NSWorkspace
    if ([url isKindOfClass:[NSURL class]]) {
        printf("\nOpening URL...\n");
        BOOL opened = [[NSWorkspace sharedWorkspace] openURL:(NSURL *)url];
        printf("Opened: %d\n", opened);
    } else {
        printf("\naction.url is not a URL, no open attempt.\n");
    }

    // --- LNAppContext.performAction ---
    // Try to invoke the action via LNAppContext.
    Class LNAppContextClass = NSClassFromString(@"LNAppContext");
    if (LNAppContextClass) {
        id ctx = [[LNAppContextClass alloc] init];
        printf("\nLNAppContext: %s\n", [[ctx description] UTF8String]);

        // performAction:options:reportingProgress:delegate:auditToken:completionHandler:
        SEL perfSel = @selector(performAction:options:reportingProgress:delegate:auditToken:completionHandler:);
        if ([ctx respondsToSelector:perfSel]) {
            printf("LNAppContext.performAction is callable\n");
            // We'd need audit_token_t for Messages.app PID. Try without (zeros).
            audit_token_t token; memset(&token, 0, sizeof(token));

            // Find Messages.app pid for audit token
            pid_t pid = 0;
            for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
                if ([app.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
                    pid = app.processIdentifier;
                    break;
                }
            }
            printf("Messages.app pid = %d\n", pid);

            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            void (^completion)(NSError *) = ^(NSError *err) {
                printf("performAction completion: err=%s\n", err ? [[err description] UTF8String] : "(no error)");
                dispatch_semaphore_signal(sem);
            };

            // performAction:options:reportingProgress:delegate:auditToken:completionHandler:
            NSMethodSignature *psig = [ctx methodSignatureForSelector:perfSel];
            NSInvocation *pinv = [NSInvocation invocationWithMethodSignature:psig];
            pinv.target = ctx;
            pinv.selector = perfSel;
            id options = nil;
            id progress = nil;
            id delegate = nil;
            [pinv setArgument:&action atIndex:2];
            [pinv setArgument:&options atIndex:3];
            [pinv setArgument:&progress atIndex:4];
            [pinv setArgument:&delegate atIndex:5];
            [pinv setArgument:&token atIndex:6];
            [pinv setArgument:&completion atIndex:7];
            [pinv invoke];
            printf("performAction invoked, waiting for completion...\n");
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
            printf("Done waiting.\n");
        }
    }

    return 0;
}
