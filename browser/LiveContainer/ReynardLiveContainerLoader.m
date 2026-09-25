//
//  ReynardLiveContainerLoader.m
//  Reynard
//

// Hosts a Gecko child process in LiveContainer's LiveProcess extension when
// Reynard runs inside LiveContainer. LiveProcess loads this dylib through its
// "customPayloadDylib" request key and calls ReynardLiveContainerPayloadMain.
// The parent side is in patches/ipc/glue/NSExtensionUtils.mm.patch.
//
// Built by Scripts/AddGecko.sh, not by an Xcode target. It only links
// Foundation, so once LiveProcess has loaded it, it can report any later
// failure back to Reynard. LiveProcess can only load it when LiveContainer
// has signed Reynard (JIT-less mode); the parent checks for that first.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/message.h>

static id LiveProcessHandlerValue(NSString *selectorName) {
    Class handler = NSClassFromString(@"LiveProcessHandler");
    SEL selector = NSSelectorFromString(selectorName);
    if (!handler || ![handler respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(handler, selector);
}

// Cancels the extension request with the error, which Reynard receives in its
// request cancellation block, then exits. LiveContainer reports a failed guest
// launch the same way.
__attribute__((noreturn)) static void FailLaunch(NSString *message) {
    NSLog(@"[Reynard] LiveContainer loader: %@", message);
    NSExtensionContext *context = LiveProcessHandlerValue(@"extensionContext");
    NSError *error = [NSError errorWithDomain:@"ReynardLiveContainerLoader"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [context cancelRequestWithError:error];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        exit(1);
    });
    for (;;) {
        CFRunLoopRun();
    }
}

__attribute__((visibility("default")))
int ReynardLiveContainerPayloadMain(int argc, char *argv[], char *envp[], char *apple[]) {
    @autoreleasepool {
        NSDictionary *appInfo = LiveProcessHandlerValue(@"retrievedAppInfo");
        if (![appInfo isKindOfClass:[NSDictionary class]]) {
            FailLaunch(@"LiveProcess did not provide the request data");
        }

        NSXPCListenerEndpoint *endpoint = appInfo[@"ReynardXPCListenerEndpoint"];
        NSString *geckoViewPath = appInfo[@"reynardGeckoViewPath"];
        NSString *greDir = appInfo[@"reynardGREDir"];
        if (![endpoint isKindOfClass:[NSXPCListenerEndpoint class]] ||
            ![geckoViewPath isKindOfClass:[NSString class]] ||
            ![greDir isKindOfClass:[NSString class]]) {
            FailLaunch(@"The request data is missing the XPC endpoint, GeckoView path or GRE directory");
        }

        // Read by GetGREDir() in dom/ipc/ContentProcess.cpp.
        setenv("REYNARD_LC_GRE_DIR", greDir.fileSystemRepresentation, 1);

        // GeckoView finds XUL and the Gecko dylibs through its
        // @loader_path/.. rpath, since @executable_path is LiveProcess here.
        void *geckoView = dlopen(geckoViewPath.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        if (!geckoView) {
            const char *reason = dlerror();
            FailLaunch([NSString stringWithFormat:@"Failed to load %@: %s", geckoViewPath,
                                                  reason ? reason : "unknown error"]);
        }

        bool (*bootstrap)(NSXPCListenerEndpoint *) =
            (bool (*)(NSXPCListenerEndpoint *))dlsym(geckoView, "ReynardChildBootstrap");
        if (!bootstrap) {
            FailLaunch(@"GeckoView does not export ReynardChildBootstrap");
        }

        if (!bootstrap(endpoint)) {
            FailLaunch(@"Failed to connect back to Reynard");
        }
    }

    // The Gecko child runs on its own thread and exits the process when it is
    // done. Keep the main thread serving the run loop and never return to
    // LiveProcess.
    for (;;) {
        CFRunLoopRun();
    }
}
