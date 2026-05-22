//
// probe-lnconn-perform.m
//
// Use LNConnectionManager to get an actual XPC connection to Messages.app,
// then use LNActionExecutor to perform the OpenMessageIntent action.
//
// This is THE path AppIntents uses internally to invoke an intent on another app:
//
//   1. LNConnectionManager.shared.connectionForEffectiveBundleIdentifier:
//        appBundleIdentifier:processInstanceIdentifier:mangledTypeName:userIdentity:error:
//      → returns an LNApplicationConnection to com.apple.MobileSMS
//   2. Build LNAction for OpenMessageIntent with target=MessageEntity(GUID)
//   3. LNConnection.executorForAction:options:delegate: returns an LNActionExecutor
//   4. [executor perform]
//
// Build:
//   clang -framework AppKit -framework Foundation -ObjC probe-lnconn-perform.m -o probe-lnconn-perform
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

int main(int argc, const char *argv[]) {
    if (argc < 3) {
        printf("usage: probe-lnconn-perform <chatGUID> <messageGUID>\n");
        return 2;
    }
    NSString *chatGUID = @(argv[1]);
    NSString *messageGUID = @(argv[2]);
    printf("chatGUID    = %s\n", [chatGUID UTF8String]);
    printf("messageGUID = %s\n", [messageGUID UTF8String]);

    dlopen("/System/Library/Frameworks/AppIntents.framework/AppIntents", RTLD_NOW);

    Class LNEntityIDClass     = NSClassFromString(@"LNEntityIdentifier");
    Class LNEntityClass       = NSClassFromString(@"LNEntity");
    Class LNValueClass        = NSClassFromString(@"LNValue");
    Class LNParameterClass    = NSClassFromString(@"LNParameter");
    Class LNActionClass       = NSClassFromString(@"LNAction");
    Class LNEntityValueType   = NSClassFromString(@"LNEntityValueType");
    Class LNConnMgrClass      = NSClassFromString(@"LNConnectionManager");
    Class LNExecOptsClass     = NSClassFromString(@"LNActionExecutorOptions");

    if (!LNEntityIDClass || !LNEntityClass || !LNValueClass || !LNParameterClass || !LNActionClass
        || !LNEntityValueType || !LNConnMgrClass || !LNExecOptsClass) {
        printf("FATAL: missing one or more classes\n");
        return 1;
    }

    // --- Build the action ---
    id entityID = [[LNEntityIDClass alloc] performSelector:@selector(initWithValue:typeName:)
                                                withObject:messageGUID
                                                withObject:@"MessageEntity"];
    id entity = [[LNEntityClass alloc] performSelector:@selector(initWithIdentifier:) withObject:entityID];
    id entityType = [[LNEntityValueType alloc] performSelector:@selector(initWithTypeName:)
                                                    withObject:@"MessageEntity"];
    id lnValue = [[LNValueClass alloc] performSelector:@selector(initWithValue:valueType:)
                                            withObject:entity withObject:entityType];
    id parameter = [[LNParameterClass alloc] performSelector:@selector(initWithIdentifier:value:)
                                                  withObject:@"target" withObject:lnValue];

    SEL actionSel = @selector(initWithIdentifier:mangledTypeName:openAppWhenRun:parameters:);
    NSMethodSignature *sig = [LNActionClass instanceMethodSignatureForSelector:actionSel];
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
    if (!action) { printf("FATAL: action nil\n"); return 1; }
    printf("action: identifier=%s mangledTypeName=%s\n",
           [[action valueForKey:@"identifier"] UTF8String],
           [[action valueForKey:@"mangledTypeName"] UTF8String]);

    // --- Get connection via LNConnectionManager ---
    id mgr = [LNConnMgrClass performSelector:@selector(sharedInstance)];
    printf("mgr: %s\n", [[mgr description] UTF8String]);

    // connectionForEffectiveBundleIdentifier:appBundleIdentifier:processInstanceIdentifier:mangledTypeName:userIdentity:error:
    SEL connSel = @selector(connectionForEffectiveBundleIdentifier:appBundleIdentifier:processInstanceIdentifier:mangledTypeName:userIdentity:error:);
    NSMethodSignature *csig = [LNConnMgrClass instanceMethodSignatureForSelector:connSel];
    if (!csig) { printf("FATAL: no signature for connection\n"); return 1; }
    NSInvocation *cinv = [NSInvocation invocationWithMethodSignature:csig];
    cinv.target = mgr;
    cinv.selector = connSel;
    NSString *bid = @"com.apple.MobileSMS";
    NSString *appBid = @"com.apple.MobileSMS";
    NSString *processID = nil;
    NSString *connMangledTypeName = mangled;  // try this — should match the OpenMessageIntent's type
    id userIdentity = nil;
    NSError *error = nil;
    [cinv setArgument:&bid atIndex:2];
    [cinv setArgument:&appBid atIndex:3];
    [cinv setArgument:&processID atIndex:4];
    [cinv setArgument:&connMangledTypeName atIndex:5];
    [cinv setArgument:&userIdentity atIndex:6];
    [cinv setArgument:&error atIndex:7];
    [cinv invoke];

    void *retainedConn = NULL;
    [cinv getReturnValue:&retainedConn];
    id conn = (__bridge id)retainedConn;
    printf("conn: %s\n", [[conn description] UTF8String]);
    printf("error: %s\n", [[error description] UTF8String] ?: "(none)");

    if (!conn) {
        printf("FATAL: no connection\n");
        return 1;
    }

    // --- Create executor options ---
    id execOpts = [[LNExecOptsClass alloc] init];
    // Maybe set source = SiriOrigin or .runtime; leave default for now
    printf("execOpts: %s\n", [[execOpts description] UTF8String]);

    // --- executorForAction:options:delegate: ---
    SEL execSel = @selector(executorForAction:options:delegate:);
    if (![conn respondsToSelector:execSel]) {
        printf("FATAL: conn doesn't respond to executorForAction:options:delegate:\n");
        return 1;
    }

    NSMethodSignature *esig = [(NSObject *)conn methodSignatureForSelector:execSel];
    NSInvocation *einv = [NSInvocation invocationWithMethodSignature:esig];
    einv.target = conn;
    einv.selector = execSel;
    id delegate = nil;
    [einv setArgument:&action atIndex:2];
    [einv setArgument:&execOpts atIndex:3];
    [einv setArgument:&delegate atIndex:4];
    [einv invoke];

    void *retainedExec = NULL;
    [einv getReturnValue:&retainedExec];
    id executor = (__bridge id)retainedExec;
    printf("executor: %s\n", [[executor description] UTF8String]);

    if (!executor) {
        printf("FATAL: no executor\n");
        return 1;
    }

    // --- Perform ---
    printf("\nCalling [executor perform]...\n");
    SEL perfSel = @selector(perform);
    if ([executor respondsToSelector:perfSel]) {
        [executor performSelector:perfSel];
    } else {
        printf("executor doesn't respond to perform\n");
    }

    printf("Sleeping 3s to let async dispatch happen...\n");
    [NSThread sleepForTimeInterval:3.0];

    printf("Done\n");
    return 0;
}
