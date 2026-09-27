//
//  AppDelegate.m
//  ReProvision
//
//  Created by Matt Clarke on 08/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "AppDelegate.h"
#import "RPVBackgroundSigningManager.h"
#import "RPVDaemonProtocol.h"
#import "RPVNotificationManager.h"
#import "RPVResources.h"

#import "RPVApplicationDatabase.h"
#import "RPVApplicationDetailController.h"
#import "RPVIpaBundleApplication.h"
#if TARGET_OS_SIMULATOR
#import "RPVAdvancedController.h"
#endif

#import <RMessageView.h>
#import "SAMKeychain.h"

#import <dlfcn.h>
#include <notify.h>
#import <objc/runtime.h>
#import <TargetConditionals.h>

#if TARGET_OS_SIMULATOR
@interface RPVAdvancedController (RPVSimulatorBackgroundSigningTest)
- (void)startBackgroundSign:(id)sender;
@end
#endif

@import Firebase;

@interface PSAppDataUsagePolicyCache : NSObject
+ (id)sharedInstance;
- (bool)setUsagePoliciesForBundle:(id)arg1 cellular:(bool)arg2 wifi:(bool)arg3;
@end

@interface AppWirelessDataUsageManager : NSObject
+ (void)setAppCellularDataEnabled:(id)arg1 forBundleIdentifier:(id)arg2 completionHandler:(/*^block*/ id)arg3;
+ (void)setAppWirelessDataOption:(id)arg1 forBundleIdentifier:(id)arg2 completionHandler:(/*^block*/ id)arg3;
@end

@interface NSXPCConnection (Private)
- (id)initWithMachServiceName:(NSString *)arg1;
@end

@interface AppDelegate ()

@property (nonatomic, strong) NSXPCConnection *daemonConnection;
@property (nonatomic, readwrite) NSUInteger daemonConnectionGeneration;
@property (nonatomic, readwrite) NSUInteger daemonReconnectAttempt;
@property (nonatomic, readwrite) BOOL daemonReconnectScheduled;
@property (nonatomic, readwrite) BOOL pendingDaemonPreferencesUpdate;
@property (nonatomic, readwrite) BOOL signingAssertionRequested;
@property (nonatomic, copy) NSString *signingAssertionIdentifier;
@property (nonatomic, readwrite) BOOL pendingDebugBackgroundSigning;
@property (nonatomic, readwrite) BOOL awaitingDebugBackgroundSigningCallback;
@property (nonatomic, readwrite) BOOL debugBackgroundSigningTestInProgress;
@property (nonatomic, readwrite) NSUInteger debugBackgroundSigningRequestGeneration;
@property (nonatomic, strong) NSMutableArray *debugBackgroundSigningCompletionHandlers;
@property (nonatomic, readwrite) BOOL applicationIsActive;
@property (nonatomic, readwrite) BOOL pendingDaemonConnectionAlert;
@property (nonatomic, readwrite) BOOL applicationSigningReportedPerAppError;
@property (nonatomic) UIAlertController *loadingAlertVC;
@property (nonatomic, readwrite) BOOL loadingAlertDismissRequested;

@end

@implementation AppDelegate

- (void)_configureAdaptiveAppearance {
    UIColor *accentColor = [UIColor colorWithRed:147.0 / 255.0
                                           green:99.0 / 255.0
                                            blue:207.0 / 255.0
                                           alpha:1.0];

    self.window.tintColor = accentColor;
    self.window.backgroundColor = [UIColor systemBackgroundColor];

    UINavigationBarAppearance *navigationAppearance = [[UINavigationBarAppearance alloc] init];
    [navigationAppearance configureWithDefaultBackground];
    navigationAppearance.backgroundColor = [UIColor systemBackgroundColor];
    navigationAppearance.titleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor labelColor] };
    navigationAppearance.largeTitleTextAttributes = @{ NSForegroundColorAttributeName: [UIColor labelColor] };

    UINavigationBar *navigationBar = [UINavigationBar appearance];
    navigationBar.tintColor = accentColor;
    navigationBar.standardAppearance = navigationAppearance;
    navigationBar.compactAppearance = navigationAppearance;
    navigationBar.scrollEdgeAppearance = navigationAppearance;

    UITabBarAppearance *tabAppearance = [[UITabBarAppearance alloc] init];
    [tabAppearance configureWithDefaultBackground];
    tabAppearance.backgroundColor = [UIColor systemBackgroundColor];

    UITabBar *tabBar = [UITabBar appearance];
    tabBar.tintColor = accentColor;
    tabBar.standardAppearance = tabAppearance;
    tabBar.scrollEdgeAppearance = tabAppearance;

    [UITableView appearance].backgroundColor = [UIColor systemGroupedBackgroundColor];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Crashlytics touches guarded exception ports on iOS 17, so leave it disabled.

    // Override point for customization after application launch.
    [[RPVApplicationSigning sharedInstance] addSigningUpdatesObserver:self];

    // Set credential accessibility before XPC can deliver a signing request.
    [SAMKeychain setAccessibilityType:kSecAttrAccessibleAfterFirstUnlock];
#if TARGET_OS_SIMULATOR
    // Simulator-only credentials are supplied explicitly by the UI test process.
    NSDictionary *environment = [NSProcessInfo processInfo].environment;
    NSString *simulatorUsername = environment[@"RPV_SIMULATOR_TEST_USERNAME"];
    NSString *simulatorPassword = environment[@"RPV_SIMULATOR_TEST_PASSWORD"];
    NSString *simulatorTeamID = environment[@"RPV_SIMULATOR_TEST_TEAM_ID"];
    if (simulatorUsername.length > 0 && simulatorPassword.length > 0 && simulatorTeamID.length > 0) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:simulatorUsername forKey:@"cachedUsername"];
        [defaults setObject:simulatorTeamID forKey:@"cachedTeamID"];
        [defaults setObject:CURRENT_CREDENTIALS_VERSION forKey:@"credentialsVersion"];
    }

    // Simulator fixture that opens Advanced settings and runs the real action.
    if ([environment[@"RPV_SIMULATOR_TEST_BACKGROUND_SIGNING_UI"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            UIViewController *rootController = self.window.rootViewController;
            UITabBarController *tabController = [rootController isKindOfClass:[UITabBarController class]]
                ? (UITabBarController *)rootController
                : nil;
            if (!tabController) {
                for (UIViewController *childController in rootController.childViewControllers) {
                    if ([childController isKindOfClass:[UITabBarController class]]) {
                        tabController = (UITabBarController *)childController;
                        break;
                    }
                }
            }
            if (!tabController || tabController.viewControllers.count == 0)
                return;

            NSUInteger settingsIndex = tabController.viewControllers.count - 1;
            UIViewController *settingsController = tabController.viewControllers[settingsIndex];
            if (![settingsController isKindOfClass:[UINavigationController class]])
                return;

            RPVAdvancedController *advancedController = [[RPVAdvancedController alloc] init];
            [(UINavigationController *)settingsController setViewControllers:@[advancedController] animated:NO];
            tabController.selectedIndex = settingsIndex;
            [advancedController loadViewIfNeeded];
            [advancedController startBackgroundSign:nil];
        });
    }
#endif
    [RPVResources migrateStoredCredentialsForBackgroundAccessIfPossible];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_protectedDataDidBecomeAvailable:)
                                                 name:UIApplicationProtectedDataDidBecomeAvailable
                                               object:nil];

    // Register the fetch mode; the daemon remains responsible for scheduling.
    [application setMinimumBackgroundFetchInterval:UIApplicationBackgroundFetchIntervalMinimum];

    // Notification permission is requested only on physical devices.
#if !TARGET_OS_SIMULATOR
    [[RPVNotificationManager sharedInstance] registerToSendNotifications];
#endif

    // Register for background signing notifications.
    [self _setupDameonConnection];

    // Ensure Chinese devices have internet access
    [self setupChinaApplicationNetworkAccess];

    // Follow system appearance while keeping ReProvision's purple accent.
    [self _configureAdaptiveAppearance];

    // Stuff for RMessage (iOS 9 only)
    [[RMessageView appearance] setMessageIcon:[UIImage imageNamed:@"notifIcon"]];
    [[RMessageView appearance] setBackgroundColor:[UIColor colorWithWhite:0.0 alpha:0.9]];

    NSLog(@"*** [ReProvision] :: applicationDidFinishLaunching, options: %@", launchOptions);


    return YES;
}

- (void)_protectedDataDidBecomeAvailable:(NSNotification *)notification {
    [RPVResources migrateStoredCredentialsForBackgroundAccessIfPossible];
}

- (void)application:(UIApplication *)application
performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler {
    NSLog(@"*** [ReProvision] :: Background-content fetch activation received");

    // A fetch may arrive before XPC; the shared manager coalesces both paths.
    [[RPVBackgroundSigningManager sharedInstance] attemptBackgroundSigningIfNecessary:^{
        completionHandler(UIBackgroundFetchResultNewData);
    }];
}

- (void)applicationWillResignActive:(UIApplication *)application {
    // nop
    self.applicationIsActive = NO;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Launched in background by daemon, or when exiting the application.
    NSLog(@"*** [ReProvision] :: applicationDidEnterBackground");
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    // nop
    NSLog(@"*** [ReProvision] :: applicationWillEnterForeground");
}


- (void)applicationDidBecomeActive:(UIApplication *)application {
    // nop
    NSLog(@"*** [ReProvision] :: applicationDidBecomeActive");

    self.applicationIsActive = YES;
    if (!self.daemonConnection && !self.daemonReconnectScheduled) {
        self.daemonReconnectAttempt = 0;
        [self _setupDameonConnection];
    }
    if (self.pendingDaemonConnectionAlert) {
        [self _notifyDaemonFailedToConnect];
        self.pendingDaemonConnectionAlert = NO;
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    // Guard case
    if (![[[url pathExtension] lowercaseString] isEqualToString:@"ipa"] && ![[url scheme] isEqualToString:@"reprovision"]) {
        [self showLoadingAlert];
        [self changeLoadingAlertText:@"Error - Invalid URL" dismissAfterDelay:2];
        return NO;
    }

    // Local imports are synchronous and do not need a loading alert.
    if ([url isFileURL] && [[[url pathExtension] lowercaseString] isEqualToString:@"ipa"]) {
        [self _showApplicationDetailControllerFromFileURL:url];
        return YES;
    }

    // Handle opening from URL scheme
    if ([[url scheme] isEqualToString:@"reprovision"] && [[url host] containsString:@"share"]) {
        // For share extension
        NSString *path = [url path];
        path = [path substringFromIndex:1];  // strip preceeding /

        url = [NSURL fileURLWithPath:path];

        NSLog(@"ReProvision :: trying to load from %@", path);

        // Incoming URL is a fileURL!
        [self _showApplicationDetailControllerFromFileURL:url];

    } else if ([[url scheme] isEqualToString:@"reprovision"] && [[url host] containsString:@"install"] && [url query]) {
        // For other applications

        // First, check params
        // Ref: https://ez-net.jp/article/7C/tje7tU1I/ip9n8f88grK2/
        NSMutableDictionary *queries = [[NSMutableDictionary alloc] init];
        NSArray *parameters = [[url query] componentsSeparatedByString:@"&"];

        for (NSString *parameter in parameters) {
            if (parameter.length > 0) {
                NSArray *elements = [parameter componentsSeparatedByString:@"="];
                id key = [elements[0] stringByRemovingPercentEncoding];
                id value = (elements.count == 1 ? @YES : [elements[1] stringByRemovingPercentEncoding]);
                [queries setObject:value forKey:key];
            }
        }

        // Next, check whether the same file exist on tmp folder.
        // If exist, delete it.
        if (!queries[@"url"]) {
            [self showLoadingAlert];
            [self changeLoadingAlertText:@"Invalid URL" dismissAfterDelay:2];
            return NO;
        }

        // Remote downloads dismiss this alert from their URLSession callbacks.
        [self showLoadingAlert];

        NSURL *tmpFolderPath = [NSURL fileURLWithPath:NSTemporaryDirectory()];
        NSString *originalFileName = [queries[@"url"] lastPathComponent];
        NSURL *tmpFilePath = [tmpFolderPath URLByAppendingPathComponent:originalFileName];
        if ([tmpFilePath checkResourceIsReachableAndReturnError:nil]) [[NSFileManager defaultManager] removeItemAtPath:[tmpFilePath path] error:nil];

        NSString *identifier = @"BackgroundSessionConfiguration";
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:identifier];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                              delegate:self
                                                         delegateQueue:nil];

        NSURL *ipaUrl = [NSURL URLWithString:queries[@"url"]];
        NSURLSessionDownloadTask *task = [session downloadTaskWithURL:ipaUrl];

        [task resume];
    }

    return YES;
}

- (void)_showApplicationDetailControllerFromFileURL:(NSURL *)url {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Create an RPVApplication for this incoming .ipa, and display the installation popup.

        RPVIpaBundleApplication *ipaApplication = [[RPVIpaBundleApplication alloc] initWithIpaURL:url];

        RPVApplicationDetailController *detailController = [[RPVApplicationDetailController alloc] initWithApplication:ipaApplication];

        // Update with current states.
        [detailController setButtonTitle:@"INSTALL"];
        detailController.lockWhenInstalling = YES;

        // Add to the rootViewController of the application, as an effective overlay.
        detailController.view.alpha = 0.0;

        UIViewController *rootController = [UIApplication sharedApplication].keyWindow.rootViewController;
        [rootController addChildViewController:detailController];
        [rootController.view addSubview:detailController.view];

        detailController.view.frame = rootController.view.bounds;

        // Animate in!
        [detailController animateForPresentation];
    });
}

- (void)showLoadingAlert {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.loadingAlertVC) {
            [self.loadingAlertVC dismissViewControllerAnimated:NO completion:nil];
        }

        self.loadingAlertDismissRequested = NO;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                        message:@"Loading..."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        self.loadingAlertVC = alert;

        UIViewController *presenter = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (presenter.presentedViewController) {
            presenter = presenter.presentedViewController;
        }

        [presenter presentViewController:alert animated:YES completion:^{
            if (self.loadingAlertVC == alert && self.loadingAlertDismissRequested) {
                [self dismissLoadingAlert];
            }
        }];
    });
}

- (void)dismissLoadingAlert {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = self.loadingAlertVC;
        if (!alert) return;

        self.loadingAlertDismissRequested = YES;

        // If presentation is still in flight, its completion retries dismissal.
        if (!alert.presentingViewController && !alert.view.window) return;

        [alert dismissViewControllerAnimated:YES completion:^{
            if (self.loadingAlertVC == alert) {
                self.loadingAlertVC = nil;
                self.loadingAlertDismissRequested = NO;
            }
        }];
    });
}

- (void)updateLoadingAlertWithProgress:(int)progress {
    if (self.loadingAlertVC) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loadingAlertVC.message = [NSString stringWithFormat:@"Loading...\n%d%%", progress];
        });
    }
}

- (void)changeLoadingAlertText:(NSString *)text dismissAfterDelay:(int)delay {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.loadingAlertVC) return;

        self.loadingAlertVC.message = text;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self dismissLoadingAlert];
        });
    });
}

- (void)application:(UIApplication *)application performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL succeeded))completionHandler {
    // Start background signing from shortcut menu
    if ([shortcutItem.type isEqualToString:@"resignExpiringNow"]) {
        [self daemonDidRequestNewBackgroundSigning];

        completionHandler(YES);
    }
}

- (void)setupChinaApplicationNetworkAccess {
    // See: https://github.com/pwn20wndstuff/Undecimus/issues/136

#if TARGET_OS_SIMULATOR
    return;
#endif

    // it is unable to load SettingsCellular.framework weakly as bitcode is enabled on this project
    // so we have to load it manually if the device is on iOS13+
    void *settingsCellular = dlopen("/System/Library/PrivateFrameworks/SettingsCellular.framework/SettingsCellular", RTLD_LAZY);

    @try {
        Class policyCacheClass = objc_getClass("PSAppDataUsagePolicyCache");
        PSAppDataUsagePolicyCache *cache = [policyCacheClass respondsToSelector:@selector(sharedInstance)] ? [policyCacheClass sharedInstance] : nil;
        if ([cache respondsToSelector:@selector(setUsagePoliciesForBundle:cellular:wifi:)]) {
            // iOS 12 through versions that still expose this private selector.
            [cache setUsagePoliciesForBundle:[NSBundle mainBundle].bundleIdentifier cellular:YES wifi:YES];
        } else {
            Class wirelessManagerClass = objc_getClass("AppWirelessDataUsageManager");
            if ([wirelessManagerClass respondsToSelector:@selector(setAppWirelessDataOption:forBundleIdentifier:completionHandler:)] &&
                [wirelessManagerClass respondsToSelector:@selector(setAppCellularDataEnabled:forBundleIdentifier:completionHandler:)]) {
                // iOS 10 - 11 fallback.
                [wirelessManagerClass setAppWirelessDataOption:[NSNumber numberWithInt:3]
                                           forBundleIdentifier:[NSBundle mainBundle].bundleIdentifier
                                             completionHandler:nil];
                [wirelessManagerClass setAppCellularDataEnabled:[NSNumber numberWithInt:1]
                                            forBundleIdentifier:[NSBundle mainBundle].bundleIdentifier
                                              completionHandler:nil];
            }
        }
    } @catch (NSException *exception) {
        // Cellular policy setup is optional and must not block launch.
        NSLog(@"*** [ReProvision] :: Unable to configure wireless data policy: %@", exception);
    }

    // close SettingsCellular as it is not needed anymore.
    if (settingsCellular) dlclose(settingsCellular);

    // Not required for iOS 9
}

//////////////////////////////////////////////////////////////////////////////////
// Application Signing delegate methods.
//////////////////////////////////////////////////////////////////////////////////

- (void)applicationSigningDidStart {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self applicationSigningDidStart]; });
        return;
    }
    // A duplicate request does not own the active pass's execution lease.
    if (self.signingAssertionRequested)
        return;
    self.applicationSigningReportedPerAppError = NO;
    self.signingAssertionRequested = YES;
    self.signingAssertionIdentifier = NSUUID.UUID.UUIDString;
    [self _requestSigningAssertionFromDaemon];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"jp.soh.reprovision/signingInProgress" object:nil];
    NSLog(@"Started signing...");
}

- (void)applicationSigningUpdateProgress:(int)percent forBundleIdentifier:(NSString *)bundleIdentifier {
    NSLog(@"'%@' at %d%%", bundleIdentifier, percent);

    if (!bundleIdentifier) bundleIdentifier = @"";

    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:bundleIdentifier forKey:@"bundleIdentifier"];
    [userInfo setObject:[NSNumber numberWithInt:percent] ?: @0 forKey:@"percent"];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"jp.soh.reprovision/signingUpdate" object:nil userInfo:userInfo];

    NSString *applicationName = [[[RPVApplicationDatabase sharedInstance] getApplicationContainsBundleIdentifier:bundleIdentifier] applicationName];

    switch (percent) {
        case 100:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Success" body:[NSString stringWithFormat:@"Signed '%@'", applicationName] isDebugMessage:NO isUrgentMessage:YES andNotificationID:nil];
            break;
        case 10:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Started signing routine for '%@'", applicationName] isDebugMessage:YES andNotificationID:nil];
            break;
        case 50:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Wrote signatures for bundle '%@'", applicationName] isDebugMessage:YES andNotificationID:nil];
            break;
        case 60:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Rebuilt IPA for bundle '%@'", applicationName] isDebugMessage:YES andNotificationID:nil];
            break;
        case 90:
            [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:[NSString stringWithFormat:@"Installing IPA for bundle '%@'", applicationName] isDebugMessage:YES andNotificationID:nil];
            break;

        default:
            break;
    }
}

- (void)applicationSigningDidEncounterError:(NSError *)error forBundleIdentifier:(NSString *)bundleIdentifier {
    self.applicationSigningReportedPerAppError = YES;
    NSLog(@"'%@' had error: %@", bundleIdentifier, error);

    NSString *applicationName = [[[RPVApplicationDatabase sharedInstance] getApplicationContainsBundleIdentifier:bundleIdentifier] applicationName];
    if (applicationName.length == 0) {
        applicationName = bundleIdentifier.length > 0 ? bundleIdentifier : @"Unknown application";
    }
    NSString *errorDescription = error.localizedDescription.length > 0 ? error.localizedDescription : @"An unknown signing error occurred.";
    [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Error" body:[NSString stringWithFormat:@"For '%@':\n%@", applicationName, errorDescription] isDebugMessage:NO isUrgentMessage:YES andNotificationID:nil];

    // Ensure the UI goes back to when signing was not occuring
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    [userInfo setObject:bundleIdentifier forKey:@"bundleIdentifier"];
    [userInfo setObject:[NSNumber numberWithInt:100] forKey:@"percent"];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"jp.soh.reprovision/signingUpdate" object:nil userInfo:userInfo];
}

- (void)applicationSigningCompleteWithError:(NSError *)error {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self applicationSigningCompleteWithError:error]; });
        return;
    }
    if (error.code == RPVErrorAlreadyUndertakingPipeline)
        return;
    NSLog(@"Completed signing, with error: %@", error);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"jp.soh.reprovision/signingComplete" object:nil];

    // Display any errors if needed.
    if (error) {
        switch (error.code) {
            case RPVErrorNoSigningRequired:
                [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Success" body:@"No applications require signing at this time" isDebugMessage:NO isUrgentMessage:NO andNotificationID:nil];
                break;
            default:
                // The per-application notification already contains this error.
                if (!self.applicationSigningReportedPerAppError) {
                    [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Error" body:error.localizedDescription isDebugMessage:NO isUrgentMessage:YES andNotificationID:nil];
                }
                break;
        }
    }
    self.applicationSigningReportedPerAppError = NO;
    if (self.signingAssertionRequested) {
        NSString *finishedIdentifier = self.signingAssertionIdentifier;
        self.signingAssertionRequested = NO;
        self.signingAssertionIdentifier = nil;
        @try {
            [[self.daemonConnection remoteObjectProxy] applicationDidFinishSigningWithIdentifier:finishedIdentifier];
        } @catch (NSException *exception) {
            // The daemon watchdog cleans up if XPC is lost.
            NSLog(@"*** [ReProvision] :: Signing lease completion could not be delivered");
        }
    }
}

//////////////////////////////////////////////////////////////////////////////////
// NSURLSession delegate methods.
//////////////////////////////////////////////////////////////////////////////////

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    // Check file size
    NSNumber *fileSizeValue = nil;
    NSError *fileSizeError = nil;
    [location getResourceValue:&fileSizeValue forKey:NSURLFileSizeKey error:&fileSizeError];

    if (fileSizeError || !fileSizeValue) {
        [self changeLoadingAlertText:@"Error - The file does not exist." dismissAfterDelay:2];
        [session finishTasksAndInvalidate];
        return;
    }

    // Successfully downloaded the file

    // Move ipa file to /tmp directory
    NSURL *tmpFolderPath = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    NSString *originalFileName = downloadTask.originalRequest.URL.lastPathComponent;
    NSURL *tmpFilePath = [tmpFolderPath URLByAppendingPathComponent:originalFileName];
    NSError *error;
    [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmpFilePath error:&error];

    if (error) {
        NSString *errorMessage = [NSString stringWithFormat:@"Error - %@", error.localizedDescription];
        [self changeLoadingAlertText:errorMessage dismissAfterDelay:2];
    } else {
        // And show application detail view
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissLoadingAlert];
        });
        [self _showApplicationDetailControllerFromFileURL:tmpFilePath];
    }

    [session finishTasksAndInvalidate];
}


- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        // Could not download the ipa file
        NSString *errorMessage = [NSString stringWithFormat:@"Error - %@", error.localizedDescription];
        NSData *resumeData = [error.userInfo objectForKey:NSURLSessionDownloadTaskResumeData];

        if ([[error.userInfo objectForKey:NSURLErrorBackgroundTaskCancelledReasonKey] integerValue] == NSURLErrorCancelledReasonUserForceQuitApplication && resumeData) {
            errorMessage = [errorMessage stringByAppendingString:@"\nThe app seems to have quit while downloading. Would you like to resume?"];

            UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil
                                                                                     message:errorMessage
                                                                              preferredStyle:UIAlertControllerStyleAlert];

            UIAlertAction *resumeButton = [UIAlertAction actionWithTitle:@"Resume"
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:^(UIAlertAction *action) {
                                                                     NSURLSessionDownloadTask *task = [session downloadTaskWithResumeData:resumeData];
                                                                     [task resume];
                                                                 }];

            UIAlertAction *cancelButton = [UIAlertAction actionWithTitle:@"Cancel"
                                                                   style:UIAlertActionStyleCancel
                                                                 handler:^(UIAlertAction *action) {
                                                                     [task cancel];
                                                                     [session finishTasksAndInvalidate];
                                                                 }];
            [alertController addAction:resumeButton];
            [alertController addAction:cancelButton];
            [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:alertController animated:YES completion:nil];
        } else {
            [self changeLoadingAlertText:errorMessage
                       dismissAfterDelay:2];
            [session finishTasksAndInvalidate];
        }
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    CGFloat progress = (int)round((float)totalBytesWritten / totalBytesExpectedToWrite * 100);
    [self updateLoadingAlertWithProgress:progress];
}

//////////////////////////////////////////////////////////////////////////////
// Automatic application signing
//////////////////////////////////////////////////////////////////////////////

- (void)_setupDameonConnection {
#if TARGET_OS_SIMULATOR
    return;
#endif

    if (![NSThread isMainThread]) {
        __weak AppDelegate *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf _setupDameonConnection];
        });
        return;
    }

    if (self.daemonConnection) {
        NSXPCConnection *previousConnection = self.daemonConnection;
        self.daemonConnection = nil;
        self.daemonConnectionGeneration++;
        [previousConnection invalidate];
    }

    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:@"jp.soh.reprovisiond"];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RPVDaemonProtocol)];

    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RPVApplicationProtocol)];
    connection.exportedObject = self;

    self.daemonConnection = connection;
    NSUInteger connectionGeneration = ++self.daemonConnectionGeneration;

    // Generations keep stale callbacks from clearing a replacement connection.
    __weak AppDelegate *weakSelf = self;
    connection.interruptionHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.daemonConnectionGeneration != connectionGeneration)
                return;

            NSLog(@"*** [ReProvision] :: Daemon connection interrupted");
            NSXPCConnection *interruptedConnection = strongSelf.daemonConnection;
            strongSelf.daemonConnection = nil;
            [interruptedConnection invalidate];
            [strongSelf _scheduleDaemonReconnect];
        });
    };

    connection.invalidationHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.daemonConnectionGeneration != connectionGeneration)
                return;

            NSLog(@"*** [ReProvision] :: Daemon connection invalidated");
            strongSelf.daemonConnection = nil;
            [strongSelf _scheduleDaemonReconnect];
        });
    };

    [connection resume];

    // Notify daemon that we've now launched
    @try {
        [[connection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
            NSLog(@"%@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                AppDelegate *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.daemonConnectionGeneration != connectionGeneration)
                    return;

                NSXPCConnection *failedConnection = strongSelf.daemonConnection;
                strongSelf.daemonConnection = nil;
                [failedConnection invalidate];
                [strongSelf _scheduleDaemonReconnect];
            });
        }] applicationDidLaunch];

    } @catch (NSException *e) {
        self.daemonConnection = nil;
        [connection invalidate];
        [self _scheduleDaemonReconnect];
        return;
    }

    if (self.pendingDaemonPreferencesUpdate) {
        self.pendingDaemonPreferencesUpdate = NO;
        [[connection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.pendingDaemonPreferencesUpdate = YES;
                [weakSelf _scheduleDaemonReconnect];
            });
        }] applicationRequestsPreferencesUpdate];
    }

    if (self.signingAssertionRequested) {
        [self _requestSigningAssertionFromDaemon];
    }

    if (self.pendingDebugBackgroundSigning) {
        [self _sendPendingDebugBackgroundSigningRequest];
    }

    // A stable connection ends the current retry sequence.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        AppDelegate *strongSelf = weakSelf;
        if (strongSelf &&
            strongSelf.daemonConnectionGeneration == connectionGeneration &&
            strongSelf.daemonConnection) {
            strongSelf.daemonReconnectAttempt = 0;
            strongSelf.pendingDaemonConnectionAlert = NO;
        }
    });

    NSLog(@"*** [ReProvision] :: Setup daemon connection generation %lu: %@", (unsigned long)connectionGeneration, connection);
}

- (void)_scheduleDaemonReconnect {
#if TARGET_OS_SIMULATOR
    return;
#endif

    if (![NSThread isMainThread]) {
        __weak AppDelegate *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf _scheduleDaemonReconnect];
        });
        return;
    }

    if (self.daemonConnection || self.daemonReconnectScheduled)
        return;

    if (self.daemonReconnectAttempt >= 5) {
        [self _notifyDaemonFailedToConnect];
        return;
    }

    NSUInteger exponent = MIN(self.daemonReconnectAttempt, (NSUInteger)3);
    NSTimeInterval delay = (NSTimeInterval)(1u << exponent);
    self.daemonReconnectAttempt++;
    self.daemonReconnectScheduled = YES;

    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        strongSelf.daemonReconnectScheduled = NO;
        if (!strongSelf.daemonConnection)
            [strongSelf _setupDameonConnection];
    });
}

- (void)_notifyDaemonFailedToConnect {
    if (!self.applicationIsActive) {
        self.pendingDaemonConnectionAlert = YES;
        return;
    }

    // That's not good...
    UIAlertController *av = [UIAlertController alertControllerWithTitle:@"Error" message:@"Could not connect to daemon; automatic background signing is disabled.\n\nPlease reinstall ReProvision, or reboot your device." preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *action = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *_Nonnull action){
    }];
    [av addAction:action];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.window.rootViewController presentViewController:av animated:YES completion:nil];
    });

    NSLog(@"*** [ReProvision] :: ERROR :: Failed to setup daemon connection: %@", self.daemonConnection);
}

- (void)_notifyDaemonOfMessageHandled {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self _notifyDaemonOfMessageHandled]; });
        return;
    }
    // Only signing completion may release an active signing lease.
    if (self.signingAssertionRequested)
        return;
    // Let the daemon know to release the background assertion.
    @try {
        [[self.daemonConnection remoteObjectProxy] applicationDidFinishTask];
    } @catch (NSException *e) {
        // Error previous shown
    }
}

- (void)_requestSigningAssertionFromDaemon {
#if TARGET_OS_SIMULATOR
    return;
#endif

    if (![NSThread isMainThread]) {
        __weak AppDelegate *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf _requestSigningAssertionFromDaemon];
        });
        return;
    }

    if (!self.signingAssertionRequested)
        return;

    if (!self.daemonConnection) {
        [self _scheduleDaemonReconnect];
        return;
    }

    NSUInteger connectionGeneration = self.daemonConnectionGeneration;
    __weak AppDelegate *weakSelf = self;
    @try {
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AppDelegate *strongSelf = weakSelf;
                if (!strongSelf || !strongSelf.signingAssertionRequested ||
                    strongSelf.daemonConnectionGeneration != connectionGeneration)
                    return;
                NSLog(@"*** [ReProvision] :: Could not request signing assertion: %@", error);
                [strongSelf _scheduleDaemonReconnect];
            });
        }] applicationRequestsSigningAssertionWithIdentifier:self.signingAssertionIdentifier];
    } @catch (NSException *exception) {
        NSLog(@"*** [ReProvision] :: Signing assertion request raised: %@", exception);
        [self _scheduleDaemonReconnect];
    }
}

- (void)daemonDidRequestNewBackgroundSigning {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self daemonDidRequestNewBackgroundSigning]; });
        return;
    }
    NSLog(@"*** [ReProvision] :: daemonDidRequestNewBackgroundSigning");

    BOOL completesDebuggingRequest = self.awaitingDebugBackgroundSigningCallback;
    if (completesDebuggingRequest) {
        self.awaitingDebugBackgroundSigningCallback = NO;
        NSUInteger signingGeneration = ++self.debugBackgroundSigningRequestGeneration;
        __weak AppDelegate *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf ||
                !strongSelf.debugBackgroundSigningTestInProgress ||
                strongSelf.debugBackgroundSigningRequestGeneration != signingGeneration)
                return;

            NSError *timeoutError = [NSError errorWithDomain:@"jp.soh.reprovision.background-signing"
                                                         code:4
                                                     userInfo:@{NSLocalizedDescriptionKey:
                                                                    @"The daemon started the background test, but signing did not finish. Check your network connection and try again."}];
            [strongSelf _completeDebugBackgroundSigningRequestWithError:timeoutError];
        });
    }

    // Start a background sign
    UIApplication *application = [UIApplication sharedApplication];
    __block BOOL backgroundRequestFinished = NO;
    UIBackgroundTaskIdentifier __block bgTask = [application beginBackgroundTaskWithName:@"ReProvision Background Signing" expirationHandler:^{
        if (backgroundRequestFinished)
            return;
        backgroundRequestFinished = YES;
        if (bgTask != UIBackgroundTaskInvalid) {
            [application endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
        [self _notifyDaemonOfMessageHandled];
    }];

    [[RPVBackgroundSigningManager sharedInstance] attemptBackgroundSigningIfNecessaryWithCompletion:^(NSError *signingError) {
        // Ask to remove our process assertion 5 seconds later, so that we can assume any notifications
        // have been scheduled.

        if (completesDebuggingRequest)
            [self _completeDebugBackgroundSigningRequestWithError:signingError];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (backgroundRequestFinished)
                return;
            backgroundRequestFinished = YES;
            [self _notifyDaemonOfMessageHandled];

            // Done, so stop this background task.
            if (bgTask != UIBackgroundTaskInvalid) {
                [application endBackgroundTask:bgTask];
                bgTask = UIBackgroundTaskInvalid;
            }
        });
    }];
}

- (void)daemonDidRequestCredentialsCheck {
    NSLog(@"*** [ReProvision] :: daemonDidRequestCredentialsCheck");

    // Check that user credentials exist, notify if not
    if (![RPVResources getUsername] ||
        [[RPVResources getUsername] isEqualToString:@""] ||
        ![RPVResources getPassword] ||
        [[RPVResources getPassword] isEqualToString:@""] ||
        ![[RPVResources getCredentialsVersion] isEqualToString:CURRENT_CREDENTIALS_VERSION]) {
        [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Login Required" body:@"Tap to login to ReProvision. This is needed to re-sign applications." isDebugMessage:NO isUrgentMessage:YES andNotificationID:@"login"];

        // Ask to remove our process assertion 5 seconds later, so that we can assume any notifications
        // have been scheduled.
        [self performSelector:@selector(_notifyDaemonOfMessageHandled) withObject:nil afterDelay:5];
    } else {
        // Nothing to do, just notify that we're done.
        [self _notifyDaemonOfMessageHandled];
    }
}

- (void)daemonDidRequestQueuedNotification {
    NSLog(@"*** [ReProvision] :: daemonDidRequestQueuedNotification");

    // Check if any applications need resigning. If they do, show notifications as appropriate.

    if ([[RPVBackgroundSigningManager sharedInstance] anyApplicationsNeedingResigning]) {
        [self _sendBackgroundedNotificationWithTitle:@"Re-signing Queued" body:@"Unlock your device to resign applications." isDebug:NO isUrgent:YES withNotificationID:@"resignQueued"];
    } else {
        [self _sendBackgroundedNotificationWithTitle:@"DEBUG" body:@"Background check has been queued for next unlock." isDebug:YES isUrgent:NO withNotificationID:nil];
    }

    [self _notifyDaemonOfMessageHandled];
}

- (void)requestDebuggingBackgroundSigning {
    [self requestDebuggingBackgroundSigningWithCompletion:nil];
}

- (void)requestDebuggingBackgroundSigningWithCompletion:(void (^)(NSError *error))completionHandler {
    if (![NSThread isMainThread]) {
        __weak AppDelegate *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf requestDebuggingBackgroundSigningWithCompletion:completionHandler];
        });
        return;
    }

    if (!self.debugBackgroundSigningCompletionHandlers)
        self.debugBackgroundSigningCompletionHandlers = [NSMutableArray array];
    if (completionHandler)
        [self.debugBackgroundSigningCompletionHandlers addObject:[completionHandler copy]];

    // Join repeated taps to the current request.
    if (self.debugBackgroundSigningTestInProgress)
        return;

    self.debugBackgroundSigningTestInProgress = YES;
    self.pendingDebugBackgroundSigning = YES;
    NSUInteger requestGeneration = ++self.debugBackgroundSigningRequestGeneration;

    // Time out if the daemon never starts the test.
    __weak AppDelegate *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.debugBackgroundSigningRequestGeneration != requestGeneration)
            return;
        if (!strongSelf.debugBackgroundSigningTestInProgress ||
            (!strongSelf.pendingDebugBackgroundSigning && !strongSelf.awaitingDebugBackgroundSigningCallback))
            return;

        NSError *timeoutError = [NSError errorWithDomain:@"jp.soh.reprovision.background-signing"
                                                     code:3
                                                 userInfo:@{NSLocalizedDescriptionKey:
                                                                @"The background daemon did not start the signing test. Reinstall ReProvision or reboot the device, then try again."}];
        [strongSelf _completeDebugBackgroundSigningRequestWithError:timeoutError];
    });

#if TARGET_OS_SIMULATOR
    // Run the same manager locally when the simulator has no daemon.
    self.pendingDebugBackgroundSigning = NO;
    self.awaitingDebugBackgroundSigningCallback = YES;
    [self daemonDidRequestNewBackgroundSigning];
#else
    if (!self.daemonConnection) {
        [self _scheduleDaemonReconnect];
        return;
    }

    [self _sendPendingDebugBackgroundSigningRequest];
#endif
}

- (void)_sendPendingDebugBackgroundSigningRequest {
    if (!self.pendingDebugBackgroundSigning || !self.daemonConnection)
        return;

    self.pendingDebugBackgroundSigning = NO;
    self.awaitingDebugBackgroundSigningCallback = YES;

    @try {
        __weak AppDelegate *weakSelf = self;
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.awaitingDebugBackgroundSigningCallback = NO;
                weakSelf.pendingDebugBackgroundSigning = YES;
                NSXPCConnection *failedConnection = weakSelf.daemonConnection;
                weakSelf.daemonConnection = nil;
                weakSelf.daemonConnectionGeneration++;
                [failedConnection invalidate];
                [weakSelf _scheduleDaemonReconnect];
            });
        }] applicationRequestsDebuggingBackgroundSigning];
    } @catch (NSException *e) {
        self.awaitingDebugBackgroundSigningCallback = NO;
        self.pendingDebugBackgroundSigning = YES;
        NSXPCConnection *failedConnection = self.daemonConnection;
        self.daemonConnection = nil;
        self.daemonConnectionGeneration++;
        [failedConnection invalidate];
        [self _scheduleDaemonReconnect];
    }
}

- (void)_completeDebugBackgroundSigningRequestWithError:(NSError *)error {
    self.pendingDebugBackgroundSigning = NO;
    self.awaitingDebugBackgroundSigningCallback = NO;
    self.debugBackgroundSigningTestInProgress = NO;
    self.debugBackgroundSigningRequestGeneration++;

    NSArray *completionHandlers = [self.debugBackgroundSigningCompletionHandlers copy];
    [self.debugBackgroundSigningCompletionHandlers removeAllObjects];

    // Use a notification when Settings is no longer active.
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) {
        BOOL noSigningRequired = error && error.code == RPVErrorNoSigningRequired;
        NSString *title = (!error || noSigningRequired) ? @"Background Signing Works" : @"Background Signing Failed";
        NSString *body = noSigningRequired
            ? @"The daemon completed the background check. No applications need signing right now."
            : (error ? error.localizedDescription : @"The daemon completed the background signing test successfully.");
        [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:title
                                                                       body:body
                                                             isDebugMessage:NO
                                                            isUrgentMessage:YES
                                                        andNotificationID:@"backgroundSigningTest"];
    }

    for (void (^handler)(NSError *) in completionHandlers)
        handler(error);
}

- (void)requestPreferencesUpdate {
    if (!self.daemonConnection) {
        self.pendingDaemonPreferencesUpdate = YES;
        [self _scheduleDaemonReconnect];
        return;
    }

    @try {
        __weak AppDelegate *weakSelf = self;
        [[self.daemonConnection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.pendingDaemonPreferencesUpdate = YES;
                [weakSelf _scheduleDaemonReconnect];
            });
        }] applicationRequestsPreferencesUpdate];
    } @catch (NSException *e) {
        self.pendingDaemonPreferencesUpdate = YES;
        [self _scheduleDaemonReconnect];
    }
}

- (void)_sendBackgroundedNotificationWithTitle:(NSString *)title body:(NSString *)body isDebug:(BOOL)isDebug isUrgent:(BOOL)isUrgent withNotificationID:(NSString *)notifID {
    // We start a background task to ensure the notification is posted when expected.
    UIApplication *application = [UIApplication sharedApplication];
    UIBackgroundTaskIdentifier __block bgTask = [application beginBackgroundTaskWithName:@"ReProvision Background Notification" expirationHandler:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;

        [self performSelector:@selector(_notifyDaemonOfMessageHandled) withObject:nil afterDelay:5];
    }];

    // Post the notification.
    [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:title body:body isDebugMessage:isDebug isUrgentMessage:isUrgent andNotificationID:notifID];

    // Done, so stop this background task.
    [application endBackgroundTask:bgTask];
    bgTask = UIBackgroundTaskInvalid;

    // Ask to remove our process assertion 5 seconds later, so that we can assume any notifications
    // have been scheduled.
    [self performSelector:@selector(_notifyDaemonOfMessageHandled) withObject:nil afterDelay:5];
}

@end
