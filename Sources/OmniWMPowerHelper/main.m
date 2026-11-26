// SPDX-License-Identifier: GPL-2.0-only
#import "OmniWMPowerMode.h"
#import <SystemConfiguration/SystemConfiguration.h>
#import <spawn.h>
#import <sys/wait.h>
#import <errno.h>

// The packager embeds the app's signing requirement in this executable.
@interface PowerHelper : NSObject <NSXPCListenerDelegate, OmniWMPowerModeService>
@end

@implementation PowerHelper
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    uid_t consoleUID;
    CFStringRef consoleUser = SCDynamicStoreCopyConsoleUser(NULL, &consoleUID, NULL);
    if (!consoleUser) return NO;
    CFRelease(consoleUser);
    if (connection.effectiveUserIdentifier != consoleUID) return NO;
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(OmniWMPowerModeService)];
    connection.exportedObject = self;
    [connection resume];
    return YES;
}

- (void)setMode:(NSInteger)mode onBattery:(BOOL)onBattery reply:(void (^)(BOOL))reply {
    static char *const values[] = {"0", "1", "2"};
    if (mode < 0 || mode >= 3) {
        reply(NO);
        return;
    }
    // Serialize profile edits, including requests from different app instances.
    dispatch_async(dispatch_get_main_queue(), ^{
        char *const args[] = {"/usr/bin/pmset", onBattery ? "-b" : "-c", "powermode", values[mode], NULL};
        char *const env[] = {NULL};
        pid_t pid;
        if (posix_spawn(&pid, args[0], NULL, NULL, args, env) != 0) {
            reply(NO);
            return;
        }
        int status;
        pid_t child;
        do { child = waitpid(pid, &status, 0); } while (child < 0 && errno == EINTR);
        reply(child == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    });
}
@end

int main(void) {
    @autoreleasepool {
        static NSXPCListener *listener;
        static PowerHelper *helper;
        listener = [[NSXPCListener alloc] initWithMachServiceName:@POWER_SERVICE_NAME];
        helper = [PowerHelper new];
        listener.delegate = helper;
        [listener setConnectionCodeSigningRequirement:@POWER_CLIENT_REQUIREMENT];
        [listener resume];
        dispatch_main();
    }
}
