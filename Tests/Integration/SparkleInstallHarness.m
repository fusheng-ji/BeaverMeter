// External updater used only by sparkle_install_test.sh against isolated demo copies.
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface SmokeDriver : NSObject <SPUUserDriver, SPUUpdaterDelegate>
@property(nonatomic, copy) NSString *feedURL;
@property(nonatomic, copy) NSString *resultPath;
@property(nonatomic, copy) NSString *targetPath;
@property(nonatomic, copy) NSString *expectedBuild;
@property(nonatomic) BOOL found;
@property(nonatomic, copy) NSString *mode;
@property(nonatomic) BOOL expectedErrorSeen;
@property(nonatomic) BOOL downloadCancelled;
@end

@implementation SmokeDriver
- (void)finish:(BOOL)success message:(NSString *)message relaunched:(BOOL)relaunched {
    NSDictionary *result = @{@"success": @(success), @"message": message, @"relaunched": @(relaunched)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToFile:self.resultPath atomically:YES];
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(success ? 0 : 1);
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    self.found = YES;
    fprintf(stderr, "Verified feed; downloading update build %s\n", item.versionString.UTF8String);
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {
    [self finish:NO message:[NSString stringWithFormat:@"Signed release notes failed: %@", error] relaunched:NO];
}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    acknowledgement();
    [self finish:NO message:[NSString stringWithFormat:@"No update found: %@", error] relaunched:NO];
}
- (BOOL)error:(NSError *)error containsCode:(NSInteger)code {
    if ([error.domain isEqual:SUSparkleErrorDomain] && error.code == code) { return YES; }
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if (underlying && [self error:underlying containsCode:code]) { return YES; }
    for (NSError *nested in error.userInfo[NSMultipleUnderlyingErrorsKey]) {
        if ([self error:nested containsCode:code]) { return YES; }
    }
    return NO;
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    BOOL expected = ([self.mode isEqual:@"bad-feed"] && error.code == SUAppcastParseError && !self.found)
        || ([self.mode isEqual:@"bad-archive"] && ([self error:error containsCode:SUSignatureError] || [self error:error containsCode:SUValidationError]))
        || ([self.mode isEqual:@"network"] && (error.code == SUAppcastError || error.code == SUDownloadError));
    if (expected) {
        self.expectedErrorSeen = YES;
        fprintf(stderr, "Expected %s rejection (Sparkle error %ld)\n", self.mode.UTF8String, (long)error.code);
        acknowledgement();
    } else {
        acknowledgement();
        [self finish:NO message:[NSString stringWithFormat:@"Unexpected Sparkle update error: %@", error] relaunched:NO];
    }
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    if ([self.mode isEqual:@"cancel-download"]) { cancellation(); }
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { fprintf(stderr, "Downloaded archive; starting verified extraction\n"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    fprintf(stderr, "Installing update (old app terminated: %s)\n", terminated ? "yes" : "no");
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    acknowledgement();
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[self.targetPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *widgetPlist = [self.targetPath stringByAppendingPathComponent:@"Contents/PlugIns/BeaverMeterWidgetExtension.appex/Contents/Info.plist"];
    NSDictionary *widget = [NSDictionary dictionaryWithContentsOfFile:widgetPlist];
    BOOL replaced = [info[@"CFBundleVersion"] isEqual:self.expectedBuild] && [widget[@"CFBundleVersion"] isEqual:self.expectedBuild];
    [self finish:(self.found && replaced && relaunched) message:(replaced && relaunched ? @"Sparkle verified, replaced App + Widget + collector, and relaunched the isolated real application" : @"Installation did not replace both bundles and relaunch") relaunched:relaunched];
}
- (void)dismissUpdateInstallation {}
- (void)userDidCancelDownload:(SPUUpdater *)updater { self.downloadCancelled = YES; }
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    if ([self.mode isEqual:@"install"]) { return; }
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[self.targetPath stringByAppendingPathComponent:@"Contents/Info.plist"]];
    BOOL unchanged = [info[@"CFBundleVersion"] isEqual:self.expectedBuild];
    BOOL observed = [self.mode isEqual:@"cancel-download"] ? self.downloadCancelled : self.expectedErrorSeen;
    [self finish:(unchanged && observed) message:(unchanged && observed ? [NSString stringWithFormat:@"PASS: %@ left the isolated app unchanged", self.mode] : @"Failure/cancellation did not leave the app unchanged") relaunched:NO];
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { return self.feedURL; }
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { return NO; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 6) {
            fprintf(stderr, "Usage: SparkleInstallHarness target.app feed-url result.json expected-build mode\n");
            return 2;
        }
        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyProhibited];
        __attribute__((objc_precise_lifetime)) SmokeDriver *driver = [SmokeDriver new];
        driver.targetPath = @(argv[1]);
        driver.feedURL = @(argv[2]);
        driver.resultPath = @(argv[3]);
        driver.expectedBuild = @(argv[4]);
        driver.mode = @(argv[5]);
        NSBundle *target = [NSBundle bundleWithPath:driver.targetPath];
        NSArray *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:target.bundleIdentifier];
        if (running.count != 1 || ![[(NSRunningApplication *)running[0] bundleURL].path isEqual:driver.targetPath]) {
            [driver finish:NO message:@"Expected exactly the isolated target application to be running" relaunched:NO];
        }
        __attribute__((objc_precise_lifetime)) SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:target applicationBundle:target userDriver:driver delegate:driver];
        NSError *error = nil;
        if (![updater startUpdater:&error]) {
            [driver finish:NO message:[NSString stringWithFormat:@"Cannot start isolated updater: %@", error] relaunched:NO];
        }
        [updater checkForUpdates];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [driver finish:NO message:@"Sparkle integration test exceeded 120 seconds" relaunched:NO];
        });
        [application run];
        // Keep the weak delegate and updater alive throughout the run loop.
        (void)driver;
        (void)updater;
    }
    return 1;
}
