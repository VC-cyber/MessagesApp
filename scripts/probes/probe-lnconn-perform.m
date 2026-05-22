//
// probe-lnconn-perform.m
//
// Use LNApplicationConnection.initWithBundleIdentifier: to get a connection to
// Messages.app, build the OpenMessageIntent LNAction, get an LNActionExecutor,
// and perform it.
//
// This is the path AppIntents uses internally to invoke an intent on another
// process.
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface NSObject (AppIntentsSPI)
- (BOOL)connectWithOptions:(id)options;
- (id)openApplicationWithOptions:(id)options completionHandler:(void (^)(NSError *))h;
- (id)executorForAction:(id)action options:(id)options delegate:(id)delegate;
- (void)setMediatorConnection:(id)c;
@end

#define LOG(...) do { fprintf(stderr, __VA_ARGS__); fflush(stderr); } while(0)

int main(int argc, const char *argv[]) {
    if (argc < 3) {
        LOG("usage: probe-lnconn-perform <chatGUID> <messageGUID>\n");
        return 2;
    }
    NSString *chatGUID = @(argv[1]);
    NSString *messageGUID = @(argv[2]);
    LOG("chatGUID    = %s\n", [chatGUID UTF8String]);
    LOG("messageGUID = %s\n", [messageGUID UTF8String]);

    dlopen("/System/Library/Frameworks/AppIntents.framework/AppIntents", RTLD_NOW);

    Class LNEntityIDClass     = NSClassFromString(@"LNEntityIdentifier");
    Class LNEntityClass       = NSClassFromString(@"LNEntity");
    Class LNValueClass        = NSClassFromString(@"LNValue");
    Class LNParameterClass    = NSClassFromString(@"LNParameter");
    Class LNActionClass       = NSClassFromString(@"LNAction");
    Class LNEntityValueType   = NSClassFromString(@"LNEntityValueType");
    Class LNAppConnClass      = NSClassFromString(@"LNApplicationConnection");
    Class LNExecOptsClass     = NSClassFromString(@"LNActionExecutorOptions");

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
    if (!action) { LOG("FATAL: action nil\n"); return 1; }
    LOG("action: identifier=%s\n",
           [[action valueForKey:@"identifier"] UTF8String]);

    // --- Get a connection to Messages.app ---
    id conn = [[LNAppConnClass alloc] performSelector:@selector(initWithBundleIdentifier:)
                                           withObject:@"com.apple.MobileSMS"];
    LOG("conn: %s\n", [[conn description] UTF8String]);
    if (!conn) { LOG("FATAL: no conn\n"); return 1; }

    // Connect with options
    Class LNConnOptsClass = NSClassFromString(@"LNMacApplicationConnectionOptions") ?:
                           NSClassFromString(@"LNConnectionOptions");
    id connOpts = nil;
    if (LNConnOptsClass) {
        id opts = [[LNConnOptsClass alloc] init];
        connOpts = opts;
    }
    LOG("connOpts: %s\n", [[connOpts description] UTF8String] ?: "(nil)");

    // Skip explicit connectWithOptions — it triggers SIGTRAP because it needs a real
    // mediator connection set up. The connection is lazy — executorForAction should
    // initialize it on demand.
    LOG("Skipping explicit connectWithOptions\n");

    // --- Create executor options ---
    id execOpts = [[LNExecOptsClass alloc] init];
    LOG("execOpts: %s\n", [[execOpts description] UTF8String]);

    // --- executorForAction:options:delegate: ---
    if (![conn respondsToSelector:@selector(executorForAction:options:delegate:)]) {
        LOG("conn doesn't respond to executorForAction:options:delegate:\n");
        return 1;
    }
    id executor = nil;
    @try {
        executor = [conn executorForAction:action options:execOpts delegate:nil];
    } @catch (NSException *e) {
        LOG("executorForAction exception: %s\n", [[e description] UTF8String]);
        return 1;
    }
    LOG("executor: %s\n", [[executor description] UTF8String]);

    if (!executor) {
        LOG("FATAL: no executor\n");
        return 1;
    }

    // --- Perform ---
    LOG("\nCalling [executor perform]...\n");
    @try {
        [executor performSelector:@selector(perform)];
    } @catch (NSException *e) {
        LOG("perform exception: %s\n", [[e description] UTF8String]);
        return 1;
    }

    LOG("Sleeping 5s to let async dispatch happen...\n");
    [NSThread sleepForTimeInterval:5.0];

    // Check state
    @try {
        LOG("executor state: %s\n", [[[executor valueForKey:@"state"] description] UTF8String]);
    } @catch (NSException *e) {
        LOG("state read exception: %s\n", [[e description] UTF8String]);
    }

    LOG("Done\n");
    return 0;
}
