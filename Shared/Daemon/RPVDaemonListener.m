//
//  RPVDaemonListener.m
//  iOS Daemon
//
//  Created by Matt Clarke on 05/07/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVDaemonListener.h"
#import <mach/mach_error.h>
#import <notify.h>
#import "Headers/IOKit/pwr_mgt/IOPMLibPrivate.h"
#import "RPVApplicationProtocol.h"

#if TARGET_OS_TV
#define APPLICATION_IDENTIFIER "jp.soh.reprovision.tvos"
#else
#define APPLICATION_IDENTIFIER "jp.soh.reprovision.ios"
#endif

///////////////////////////////////////////////////////////////////////////
// Private API
///////////////////////////////////////////////////////////////////////////

#if __cplusplus
extern "C" {
#endif
// SpringBoardServices
BOOL SBSProcessIDForDisplayIdentifier(CFStringRef identifier, pid_t *pid);

// Needs the com.apple.backboardd.launchapplications entitlement
int SBSLaunchApplicationWithIdentifier(CFStringRef identifier, BOOL suspended);
int SBSLaunchApplicationWithIdentifierAndLaunchOptions(CFStringRef identifier, CFDictionaryRef launchOptions, BOOL suspended);
CFStringRef SBSApplicationLaunchingErrorString(int error);

// BackBoardServices

#define BKSProcessAssertionFlagNone 0
#define BKSProcessAssertionFlagPreventSuspend (1 << 0)
#define BKSProcessAssertionFlagPreventThrottleDownCPU (1 << 1)
#define BKSProcessAssertionFlagAllowIdleSleep (1 << 2)
#define BKSProcessAssertionFlagWantsForegroundResourcePriority (1 << 3)

typedef enum {
    BKSProcessAssertionReasonNone,
    BKSProcessAssertionReasonAudio,
    BKSProcessAssertionReasonLocation,
    BKSProcessAssertionReasonExternalAccessory,
    BKSProcessAssertionReasonFinishTask,
    BKSProcessAssertionReasonBluetooth,
    BKSProcessAssertionReasonNetworkAuthentication,
    BKSProcessAssertionReasonBackgroundUI,
    BKSProcessAssertionReasonInterAppAudioStreaming,
    BKSProcessAssertionReasonViewServices
} BKSProcessAssertionReason;

#if __cplusplus
}
#endif

extern NSString *BKSActivateForEventOptionTypeBackgroundContentFetching;
extern NSString *BKSOpenApplicationOptionKeyActivateForEvent;

@interface BKSProcessAssertion : NSObject
- (id)initWithPID:(pid_t)arg1 flags:(unsigned int)arg2 reason:(BKSProcessAssertionReason)arg3 name:(NSString *)arg4 withHandler:(void (^)(BOOL success))arg5;
- (void)invalidate;
@end

typedef enum : NSUInteger {
    kNewSigningRoutine,
    kCheckForCredentials,
    kShowQueuedUpdate,
} RPVApplicationNotification;

///////////////////////////////////////////////////////////////////////////
// Main daemon class
///////////////////////////////////////////////////////////////////////////

@interface RPVDaemonListener ()

@property (nonatomic, strong) NSDictionary *settings;

@property (nonatomic, strong) NSTimer *assertionFallbackTimer;

@property (nonatomic, readwrite) BOOL updateQueuedForUnlock;
@property (nonatomic, readwrite) BOOL showQueuedAlertWhenDisplayOn;
@property (nonatomic, readwrite) BOOL displayState;
@property (nonatomic, readwrite) BOOL springboardDidLaunchSeen;

@property (nonatomic, strong) NSTimer *signingTimer;
@property (nonatomic, strong) NSTimer *applicationLaunchRetryTimer;
@property (nonatomic, readwrite) NSUInteger applicationLaunchRetryAttempt;

@property (nonatomic, strong) BKSProcessAssertion *applicationBackgroundAssertion;
@property (nonatomic, readwrite) pid_t applicationAssertionPID;
@property (nonatomic, readwrite) NSUInteger applicationAssertionGeneration;
@property (nonatomic, readwrite) IOPMAssertionID signingPowerAssertion;
@property (nonatomic, copy) NSString *activeSigningIdentifier;
@property (nonatomic, strong) NSXPCConnection *xpcConnection;
@property (nonatomic, readwrite) NSUInteger xpcConnectionGeneration;
@property (nonatomic, strong) NSMutableArray *pendingXpcConnectionQueue;

@end

@implementation RPVDaemonListener

#if !TARGET_OS_SIMULATOR
static const NSUInteger RPVMaximumBackgroundLaunchRetries = 5;
static const NSTimeInterval RPVSigningAssertionFallbackInterval = 300.0;
#endif

- (void)_performOnMainThread:(dispatch_block_t)block {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (void)reloadSettings {
    // Reload settings.
    NSLog(@"*** [reprovisiond] :: Reloading settings");

    CFPreferencesSynchronize(CFSTR(APPLICATION_IDENTIFIER), CFSTR("mobile"), kCFPreferencesCurrentHost);

    // Read the same mobile/current-host preference domain written by the app.
    CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR(APPLICATION_IDENTIFIER), CFSTR("mobile"), kCFPreferencesCurrentHost);

    if (!keyList) {
        self.settings = [NSMutableDictionary dictionary];
    } else {
        CFDictionaryRef dictionary = CFPreferencesCopyMultiple(keyList, CFSTR(APPLICATION_IDENTIFIER), CFSTR("mobile"), kCFPreferencesCurrentHost);

        self.settings = [(__bridge NSDictionary *)dictionary copy];

        CFRelease(dictionary);
        CFRelease(keyList);
    }
}

- (void)setPreferenceKey:(NSString *)key withValue:(id)value {
    if (!key || !value) {
        NSLog(@"*** [reprovisiond] :: Not setting value, as one of the arguments is null");
        return;
    }

    NSMutableDictionary *mutableSettings = [self.settings mutableCopy];

    [mutableSettings setObject:value forKey:key];

    // Write to CFPreferences
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(APPLICATION_IDENTIFIER), CFSTR("mobile"), kCFPreferencesCurrentHost);

    self.settings = mutableSettings;

    // Sync
    CFPreferencesSynchronize(CFSTR(APPLICATION_IDENTIFIER), CFSTR("mobile"), kCFPreferencesCurrentHost);
}

- (id)getPreferenceKey:(NSString *)key {
    return [self.settings objectForKey:key];
}

- (void)initialiseListener {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf initialiseListener];
        }];
        return;
    }

    // Setup notifications
    [self setupNotifyPosts];

    // Start timer for signing etc
    [self reloadSettings];

    // Setup states - assuming that we're starting with Cydia etc open
    // If from reboot, SpringBoard states will override this
    self.updateQueuedForUnlock = NO;
    self.displayState = YES;

    // Load from disk the next fire date, and adjust signing timer for that
    [self _startSigningTimer];
}

- (void)_startSigningTimer {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf _startSigningTimer];
        }];
        return;
    }

    NSDate *nextFireDate = [self getPreferenceKey:@"nextFireDate"];
    NSTimeInterval nextFireInterval = [self heartbeatTimerInterval];

    NSLog(@"*** [reprovisiond] :: DEBUG :: Got stored fire date: %@", nextFireDate);

    if (nextFireDate != nil) {
        nextFireInterval = [nextFireDate timeIntervalSinceDate:[NSDate date]];

        if (nextFireInterval < 0) {
            NSLog(@"*** [reprovisiond] :: DEBUG :: Fire date has been and gone whilst reprovisiond was not running!");
            nextFireInterval = 5;  // seconds
        }
    }

    NSLog(@"*** [reprovisiond] :: Starting signing timer, next fire in: %f minutes", (float)nextFireInterval / 60.0);

    [self _replaceSigningTimerWithInterval:nextFireInterval];
}

- (void)_restartSigningTimerWithInterval:(NSTimeInterval)interval {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf _restartSigningTimerWithInterval:interval];
        }];
        return;
    }

    NSLog(@"*** [reprovisiond] :: Restarting signing timer, next fire in: %f minutes", (float)interval / 60.0);

    [self _replaceSigningTimerWithInterval:interval];
}

- (void)_replaceSigningTimerWithInterval:(NSTimeInterval)interval {
    NSAssert([NSThread isMainThread], @"Signing timers must be managed on the daemon main thread");

    interval = MAX(interval, 1.0);

    if (self.signingTimer)
        [self.signingTimer invalidate];

    self.signingTimer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(signingTimerDidFire:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.signingTimer forMode:NSRunLoopCommonModes];

    // Keep the run-loop timer and hardware wake on the same persisted date.
    NSDate *nextFireDate = self.signingTimer.fireDate;
    [self setPreferenceKey:@"nextFireDate" withValue:nextFireDate];
    [self _scheduleWakeForSigningDate:nextFireDate];
}

- (void)_scheduleWakeForSigningDate:(NSDate *)signingDate {
    NSAssert([NSThread isMainThread], @"Wake events must be managed on the daemon main thread");

#if TARGET_OS_SIMULATOR
    return;
#else
    [self _cancelAllWakeTimer];

    if (![self shouldAutomaticallyResign] || ![self trueBgResign] || !signingDate)
        return;

    // Schedule the hardware wake shortly before the software timer.
    NSDate *wakeTime = [signingDate dateByAddingTimeInterval:-10.0];
    NSDate *minimumWakeTime = [NSDate dateWithTimeIntervalSinceNow:1.0];
    if ([wakeTime compare:minimumWakeTime] == NSOrderedAscending)
        wakeTime = minimumWakeTime;

    IOReturn ret = IOPMSchedulePowerEvent((__bridge CFDateRef)wakeTime, CFSTR("jp.soh.reprovisiond"), CFSTR(kIOPMAutoWakeOrPowerOn));
    if (ret == kIOReturnSuccess)
        NSLog(@"*** [reprovisiond] :: Successfully scheduled background wake for %@", wakeTime);
    else
        NSLog(@"*** [reprovisiond] :: Failed to schedule background wake: %s", mach_error_string(ret));

    CFMutableDictionaryRef scheduleDict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryAddValue(scheduleDict, CFSTR(kIOPMPowerEventTimeKey), (__bridge CFDateRef)[wakeTime dateByAddingTimeInterval:5]);
    CFDictionaryAddValue(scheduleDict, CFSTR(kIOPMPowerEventAppNameKey), CFSTR("jp.soh.reprovisiond"));
    CFDictionaryAddValue(scheduleDict, CFSTR(kIOPMPowerEventUserVisible), kCFBooleanTrue);

    ret = IOPMRequestSysWake(scheduleDict);
    if (ret == kIOReturnSuccess)
        NSLog(@"*** [reprovisiond] :: Successfully requested system wake for %@", wakeTime);
    else
        NSLog(@"*** [reprovisiond] :: Failed to request system wake: %s", mach_error_string(ret));
    CFRelease(scheduleDict);
#endif
}

- (void)_cancelAllWakeTimer {
#if TARGET_OS_SIMULATOR
    return;
#else
    CFArrayRef events = IOPMCopyScheduledPowerEvents();
    if (events) {
        int i;
        CFIndex count = CFArrayGetCount(events);
        for (i = 0; i < count; i++) {
            CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(events, i);
            CFStringRef id = (CFStringRef)CFDictionaryGetValue(dict, CFSTR(kIOPMPowerEventAppNameKey));
            if (id && CFEqual(id, CFSTR("jp.soh.reprovisiond"))) {
                CFDateRef EventTime = (CFDateRef)CFDictionaryGetValue(dict, CFSTR(kIOPMPowerEventTimeKey));
                CFStringRef EventType = (CFStringRef)CFDictionaryGetValue(dict, CFSTR(kIOPMPowerEventTypeKey));
                IOReturn ret = IOPMCancelScheduledPowerEvent(EventTime, id, EventType);
                if (ret == kIOReturnSuccess)
                    NSLog(@"Success cancel scheduled power event(s)");
                else
                    NSLog(@"Error: %s", mach_error_string(ret));
            }
        }
        CFRelease(events);
    }
#endif
}

- (NSTimeInterval)heartbeatTimerInterval {
    id value = [self.settings objectForKey:@"heartbeatTimerInterval"];
    int time = value ? [value intValue] : 2;

    NSTimeInterval interval = 3600;
    interval *= time;

    return interval;
}

- (BOOL)canSignInLowPowerMode {
    id value = [self.settings objectForKey:@"resignInLowPowerMode"];
    return value ? [value boolValue] : NO;
}

- (BOOL)trueBgResign {
    id value = [self.settings objectForKey:@"trueBgResign"];
    // Enable scheduled wakes by default unless the user disables them.
    return value ? [value boolValue] : YES;
}

- (BOOL)shouldAutomaticallyResign {
    id value = [self.settings objectForKey:@"resign"];
    return value ? [value boolValue] : YES;
}

- (void)signingTimerDidFire:(id)sender {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf signingTimerDidFire:sender];
        }];
        return;
    }

    // Do checks for Low Power Mode stuff.
    BOOL isInLPM = [[NSProcessInfo processInfo] isLowPowerModeEnabled];
    if (isInLPM && ![self canSignInLowPowerMode]) {
        NSLog(@"*** [reprovisiond] :: Signing skipped: in Low Power Mode, and user set to not sign.");
        [self _restartSigningTimerWithInterval:[self heartbeatTimerInterval]];
        return;
    }

    if (![self shouldAutomaticallyResign]) {
        NSLog(@"*** [reprovisiond] :: Signing skipped: user disabled automatic re-signing.");
        [self.signingTimer invalidate];
        self.signingTimer = nil;
        [self _cancelAllWakeTimer];
        return;
    }

    NSLog(@"*** [reprovisiond] :: Signing timer fired: update now");
    [self _initiateNewSigningRoutine];

    // Restart the timer with the full duration.
    [self _restartSigningTimerWithInterval:[self heartbeatTimerInterval]];
}

- (void)_initiateNewSigningRoutine {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf _initiateNewSigningRoutine];
        }];
        return;
    }

    // Launch our companion app backgrounded, and update the notification flag for it to
    // then initiate signing.
    NSLog(@"*** [reprovisiond] :: Starting new background signing routine.");
    [self _launchApplicationBackgroundedWithNotification:kNewSigningRoutine];
}

- (void)_initiateApplicationCheckForCredentials {
    // Launch our companion app backgrounded, and update the notification flag for it to
    // then initiate credential checks..
    NSLog(@"*** [reprovisiond] :: Requesting application to check login credentials.");
    [self _launchApplicationBackgroundedWithNotification:kCheckForCredentials];
}

- (void)_showApplicationNotificationForQueuedUpdate {
    NSLog(@"*** [reprovisiond] :: Requesting application to notify users of a queued update.");
    [self _launchApplicationBackgroundedWithNotification:kShowQueuedUpdate];
}

- (void)_launchApplicationBackgroundedWithNotification:(RPVApplicationNotification)notification {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf _launchApplicationBackgroundedWithNotification:notification];
        }];
        return;
    }

    // Launch the application
    int result = [self _launchApplicationBackgroundedAndAquireAssertion];
    if (result) {
        // Error occured in launch.
#if TARGET_OS_SIMULATOR
#else
        NSLog(@"*** [reprovisiond] :: Error launching application: %@", SBSApplicationLaunchingErrorString(result));
#endif
    }

    // Queue notifications when not connected
    if (!self.xpcConnection) {
        [self remoteObjectProxyErrorHandler:notification];
        [self _scheduleApplicationLaunchRetry];
        return;
    }

    // And call the remote XPC
    switch (notification) {
        case kNewSigningRoutine: {
            [[self.xpcConnection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
                [self remoteObjectProxyErrorHandler:notification];
            }] daemonDidRequestNewBackgroundSigning];
            break;
        }
        case kCheckForCredentials: {
            [[self.xpcConnection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
                [self remoteObjectProxyErrorHandler:notification];
            }] daemonDidRequestCredentialsCheck];
            break;
        }
        case kShowQueuedUpdate: {
            [[self.xpcConnection remoteObjectProxyWithErrorHandler:^(NSError *_Nonnull error) {
                [self remoteObjectProxyErrorHandler:notification];
            }] daemonDidRequestQueuedNotification];
            break;
        }
    }
}

- (void)remoteObjectProxyErrorHandler:(RPVApplicationNotification)notification {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf remoteObjectProxyErrorHandler:notification];
        }];
        return;
    }

    NSLog(@"*** reprovisiond :: Queuing notification %lu until connection is established", (unsigned long)notification);
    // Drop the message onto a queue, and go from there
    if (!self.pendingXpcConnectionQueue)
        self.pendingXpcConnectionQueue = [NSMutableArray array];

    NSNumber *queuedNotification = [NSNumber numberWithUnsignedInteger:notification];
    if (![self.pendingXpcConnectionQueue containsObject:queuedNotification])
        [self.pendingXpcConnectionQueue addObject:queuedNotification];

    [self _scheduleApplicationLaunchRetry];
}

- (void)_scheduleApplicationLaunchRetry {
    NSAssert([NSThread isMainThread], @"Application launch retries must run on the daemon main thread");

#if TARGET_OS_SIMULATOR
    return;
#else
    if (self.xpcConnection || self.applicationLaunchRetryTimer)
        return;

    if (self.applicationLaunchRetryAttempt >= RPVMaximumBackgroundLaunchRetries) {
        NSLog(@"*** [reprovisiond] :: Background launch did not connect after %lu attempts; deferring the queued task until the next unlock", (unsigned long)self.applicationLaunchRetryAttempt);
        self.updateQueuedForUnlock = YES;
        return;
    }

    NSUInteger retryExponent = MIN(self.applicationLaunchRetryAttempt, (NSUInteger)3);
    NSTimeInterval retryDelay = (NSTimeInterval)(1u << retryExponent);
    self.applicationLaunchRetryAttempt++;
    self.applicationLaunchRetryTimer = [NSTimer timerWithTimeInterval:retryDelay target:self selector:@selector(_applicationLaunchRetryDidFire:) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.applicationLaunchRetryTimer forMode:NSRunLoopCommonModes];
    NSLog(@"*** [reprovisiond] :: Retrying background application launch in %.0f second(s)", retryDelay);
#endif
}

- (void)_applicationLaunchRetryDidFire:(NSTimer *)timer {
    self.applicationLaunchRetryTimer = nil;

    if (self.xpcConnection) {
        self.applicationLaunchRetryAttempt = 0;
        [self applicationDidLaunch];
        return;
    }

    int result = [self _launchApplicationBackgroundedAndAquireAssertion];
    if (result)
        NSLog(@"*** [reprovisiond] :: Background application retry failed: %@", SBSApplicationLaunchingErrorString(result));

    if (!self.xpcConnection)
        [self _scheduleApplicationLaunchRetry];
}

- (int)_launchApplicationBackgroundedAndAquireAssertion {
#if TARGET_OS_SIMULATOR
    return 0;
#else

    pid_t servicePid = 0;
    SBSProcessIDForDisplayIdentifier(CFSTR(APPLICATION_IDENTIFIER), &servicePid);

    // If running, do assertion now.
    if (servicePid != 0) {
        [self _aquireApplicationBackgroundAssertion];
    }

    NSMutableDictionary *launchOptions = [@{} mutableCopy];
    NSDictionary *eventOptions = @{ BKSActivateForEventOptionTypeBackgroundContentFetching: @"" };

    [launchOptions setObject:eventOptions forKey:BKSOpenApplicationOptionKeyActivateForEvent];

    int result = SBSLaunchApplicationWithIdentifierAndLaunchOptions(CFSTR(APPLICATION_IDENTIFIER), (__bridge CFDictionaryRef)(launchOptions), 1);

    // Fall back to a suspended launch when the activation options are rejected.
    if (result != 0)
        result = SBSLaunchApplicationWithIdentifier(CFSTR(APPLICATION_IDENTIFIER), 1);

    NSLog(@"*** [reprovisiond] :: Launched application with result: %d", result);
    if (result == 0 && servicePid == 0) {
        // Aquire assertion now that we're launched.
        // The retry loop acquires the assertion once SpringBoard registers the PID.
        [self _aquireApplicationBackgroundAssertion];
    }

    return result;
#endif
}

- (void)_aquireApplicationBackgroundAssertion {
#if TARGET_OS_SIMULATOR
    return;
#else
    pid_t servicePid = 0;
    SBSProcessIDForDisplayIdentifier(CFSTR(APPLICATION_IDENTIFIER), &servicePid);
    if (self.applicationBackgroundAssertion && self.applicationAssertionPID != servicePid)
        [self _releaseApplicationBackgroundAssertion];

    if (self.applicationBackgroundAssertion) {
        // Refresh the watchdog when an active signing pass moves to the background.
        [self.assertionFallbackTimer invalidate];
        self.assertionFallbackTimer = [NSTimer timerWithTimeInterval:RPVSigningAssertionFallbackInterval
                                                               target:self
                                                             selector:@selector(_assertionFallbackDidFire:)
                                                             userInfo:nil
                                                              repeats:NO];
        [[NSRunLoop mainRunLoop] addTimer:self.assertionFallbackTimer forMode:NSRunLoopCommonModes];
        return;
    }

    if (servicePid != 0) {
        NSLog(@"*** [reprovisiond] :: Aquiring background assertion");

        __weak RPVDaemonListener *weakSelf = self;
        NSUInteger generation = ++self.applicationAssertionGeneration;
        self.applicationAssertionPID = servicePid;

        self.applicationBackgroundAssertion = [[BKSProcessAssertion alloc] initWithPID:servicePid flags:(BKSProcessAssertionFlagPreventSuspend | BKSProcessAssertionFlagAllowIdleSleep) reason:BKSProcessAssertionReasonFinishTask name:@APPLICATION_IDENTIFIER withHandler:^(BOOL success) {
            // Defer the callback because it may run before the property assignment.
            dispatch_async(dispatch_get_main_queue(), ^{
                RPVDaemonListener *strongSelf = weakSelf;
                if (!strongSelf || strongSelf.applicationAssertionGeneration != generation)
                    return;

                if (success) {
                    NSLog(@"*** [reprovisiond] :: Did aquire background assertion");

                    // Run the watchdog on the daemon's main run loop.
                    [strongSelf.assertionFallbackTimer invalidate];
                    strongSelf.assertionFallbackTimer = [NSTimer timerWithTimeInterval:RPVSigningAssertionFallbackInterval target:strongSelf selector:@selector(_assertionFallbackDidFire:) userInfo:nil repeats:NO];
                    [[NSRunLoop mainRunLoop] addTimer:strongSelf.assertionFallbackTimer forMode:NSRunLoopCommonModes];
                } else {
                    NSLog(@"*** [reprovisiond] :: Failed to aquire background assertion");
                    [strongSelf _releaseApplicationBackgroundAssertion];
                }
            });
        }];
    } else {
        // No PID!
        NSLog(@"*** [reprovisiond] :: Could not find application's PID, might be first launch.");
    }
#endif
}

- (void)_assertionFallbackDidFire:(id)sender {
    NSLog(@"*** [reprovisiond] :: Background assertion fallback did fire.");
    self.activeSigningIdentifier = nil;
    [self _releaseApplicationBackgroundAssertion];
}

- (void)_acquireSigningPowerAssertion {
#if !TARGET_OS_SIMULATOR
    if (self.signingPowerAssertion != kIOPMNullAssertionID)
        return;
    // Keep signing eligible during sleep without waking or unlocking the display.
    NSDictionary *properties = @{
        (__bridge NSString *)kIOPMAssertionTypeKey: (__bridge NSString *)kIOPMAssertionTypePreventUserIdleSystemSleep,
        (__bridge NSString *)kIOPMAssertionNameKey: @"ReProvision active signing",
        (__bridge NSString *)kIOPMAssertionLevelKey: @(kIOPMAssertionLevelOn),
        (__bridge NSString *)kIOPMAssertionTimeoutKey: @(RPVSigningAssertionFallbackInterval),
        (__bridge NSString *)kIOPMAssertionTimeoutActionKey: (__bridge NSString *)kIOPMAssertionTimeoutActionTurnOff
    };
    IOPMAssertionID assertion = kIOPMNullAssertionID;
    IOReturn result = IOPMAssertionCreateWithProperties((__bridge CFDictionaryRef)properties, &assertion);
    if (result == kIOReturnSuccess) self.signingPowerAssertion = assertion;
    NSLog(@"*** [reprovisiond] :: Signing power assertion result: %d", result);
#endif
}

- (void)_releaseApplicationBackgroundAssertion {
#if TARGET_OS_SIMULATOR
    return;
#else
    NSLog(@"*** [reprovisiond] :: Releasing background assertion");
    self.applicationAssertionGeneration++;
    self.applicationAssertionPID = 0;
    if (self.signingPowerAssertion != kIOPMNullAssertionID) {
        IOPMAssertionRelease(self.signingPowerAssertion);
        self.signingPowerAssertion = kIOPMNullAssertionID;
    }

    if (self.assertionFallbackTimer) {
        [self.assertionFallbackTimer invalidate];
        self.assertionFallbackTimer = nil;
    }

    [self.applicationBackgroundAssertion invalidate];
    self.applicationBackgroundAssertion = nil;
#endif
}

- (void)sb_didFinishLaunchingNotification {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf sb_didFinishLaunchingNotification];
        }];
        return;
    }

    // Give the user a notification if they need to sign in to ReProvision after a respring/restart
    NSLog(@"*** [reprovisiond] :: SpringBoard did start launching.");

    // Setup state for new SpringBoard launch
    self.springboardDidLaunchSeen = YES;
    self.displayState = NO;
}

- (void)sb_didUIUnlockNotification {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf sb_didUIUnlockNotification];
        }];
        return;
    }

    // Start a signing routine since we had one trigger whilst locked.
    NSLog(@"*** [reprovisiond] :: Device was unlocked.");

    //    self.uiLockState = NO;

    // Handle queued signing
    if (self.updateQueuedForUnlock) {
        self.updateQueuedForUnlock = NO;
        self.applicationLaunchRetryAttempt = 0;

        if (self.pendingXpcConnectionQueue.count > 0) {
            int result = [self _launchApplicationBackgroundedAndAquireAssertion];
            if (result)
                NSLog(@"*** [reprovisiond] :: Unlock retry failed to launch application: %@", SBSApplicationLaunchingErrorString(result));
            if (!self.xpcConnection)
                [self _scheduleApplicationLaunchRetry];
        } else {
            [self _initiateNewSigningRoutine];
        }

        // Restart timer now with full duration!
        [self _restartSigningTimerWithInterval:[self heartbeatTimerInterval]];
    }

    // Handle launching the app for credentials checks after SpringBoard launches
    // e.g., this should be the first unlock
    if (self.springboardDidLaunchSeen) {
        self.springboardDidLaunchSeen = NO;

        NSLog(@"*** [reprovisiond] :: Checking credentials after reaching a sane point since SpringBoard launched.");
        [self _initiateApplicationCheckForCredentials];
    }
}

- (void)bb_backlightChanged:(int)state {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf bb_backlightChanged:state];
        }];
        return;
    }

    self.displayState = state > 0;

    if (state > 0) {
        NSLog(@"*** [reprovisiond] :: Display turned on");

        // Restarting timer as needed.
        {
            NSDate *nextFireDate = [self getPreferenceKey:@"nextFireDate"];
            NSTimeInterval nextFireInterval = [nextFireDate timeIntervalSinceDate:[NSDate date]];

            if (nextFireInterval <= 5) {  // seconds
                NSLog(@"*** [reprovisiond] :: DEBUG :: Timer would have (or is about to) expire, so requesting signing checks");
                NSLog(@"state: %i / nextFireDate: %@ / nextFireInterval: %f", state, nextFireDate, nextFireInterval);
                [self signingTimerDidFire:nil];
            } else {
                // Restart the timer for this remaining interval
                NSLog(@"*** [reprovisiond] :: DEBUG :: Restarting signing timer due to wake, with interval: %f minutes", (float)nextFireInterval / 60.0);
                [self _restartSigningTimerWithInterval:nextFireInterval];
            }
        }
    } else {
        NSLog(@"*** [reprovisiond] :: Display turned off");

        // The daemon stays alive while the display sleeps, so keep its timer armed.
        NSLog(@"*** [reprovisiond] :: DEBUG :: Keeping signing timer armed while display is off");
    }
}

//////////////////////////////////////////////////////////////////////////
// XPC Handling
//////////////////////////////////////////////////////////////////////////

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    // Configure bi-directional communication
    NSLog(@"*** [reprovisiond] :: shouldAcceptNewConnection recieved.");

    [newConnection setExportedInterface:[NSXPCInterface interfaceWithProtocol:@protocol(RPVDaemonProtocol)]];
    [newConnection setExportedObject:self];

    NSXPCConnection *previousConnection = self.xpcConnection;
    self.xpcConnection = nil;
    self.xpcConnectionGeneration++;
    [previousConnection invalidate];

    self.xpcConnection = newConnection;
    NSUInteger connectionGeneration = ++self.xpcConnectionGeneration;

    // State management for the main application
    // When it is e.g. killed, then the invalidation handler is called
    __weak RPVDaemonListener *weakSelf = self;
    newConnection.interruptionHandler = ^{
        [weakSelf _performOnMainThread:^{
            RPVDaemonListener *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.xpcConnectionGeneration != connectionGeneration)
                return;

            NSLog(@"*** reprovisiond :: XPC interruption handler called");
            NSXPCConnection *interruptedConnection = strongSelf.xpcConnection;
            strongSelf.xpcConnection = nil;
            [interruptedConnection invalidate];
        }];
    };
    newConnection.invalidationHandler = ^{
        [weakSelf _performOnMainThread:^{
            RPVDaemonListener *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.xpcConnectionGeneration != connectionGeneration)
                return;

            NSLog(@"*** reprovisiond :: XPC invalidation handler called");
            strongSelf.xpcConnection = nil;
        }];
    };

    newConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RPVApplicationProtocol)];
    [newConnection resume];

    return YES;
}

- (void)applicationDidLaunch {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf applicationDidLaunch];
        }];
        return;
    }

    [self.applicationLaunchRetryTimer invalidate];
    self.applicationLaunchRetryTimer = nil;
    self.applicationLaunchRetryAttempt = 0;

    if (!self.pendingXpcConnectionQueue || self.pendingXpcConnectionQueue.count == 0) {
        NSLog(@"*** reprovisiond :: No pending notifications");
        if (!self.activeSigningIdentifier)
            [self _releaseApplicationBackgroundAssertion];

        return;
    }

    NSLog(@"*** reprovisiond :: Forwarding pending notifications");

    // XPC setup confirms the PID is registered; acquire the assertion again here.
    [self _aquireApplicationBackgroundAssertion];

    for (NSNumber *number in self.pendingXpcConnectionQueue) {
        RPVApplicationNotification notification = [number unsignedIntegerValue];

        switch (notification) {
            case kNewSigningRoutine:
                [[self.xpcConnection remoteObjectProxy] daemonDidRequestNewBackgroundSigning];
                break;
            case kCheckForCredentials:
                [[self.xpcConnection remoteObjectProxy] daemonDidRequestCredentialsCheck];
                break;
            case kShowQueuedUpdate:
                [[self.xpcConnection remoteObjectProxy] daemonDidRequestQueuedNotification];
                break;
        }
    }

    [self.pendingXpcConnectionQueue removeAllObjects];
}

//////////////////////////////////////////////////////////////////////////
// Daemon protocol
//////////////////////////////////////////////////////////////////////////

- (void)applicationDidFinishTask {
    if (![NSThread isMainThread]) {
        [self _performOnMainThread:^{ [self applicationDidFinishTask]; }];
        return;
    }
    NSLog(@"*** [reprovisiond] :: applicationDidFinishTask recieved.");

    if (self.activeSigningIdentifier) {
        NSLog(@"*** [reprovisiond] :: Keeping execution lease: signing is still active");
        return;
    }
    [self _releaseApplicationBackgroundAssertion];
}

- (void)applicationRequestsSigningAssertionWithIdentifier:(NSString *)identifier {
    if (![NSThread isMainThread]) {
        [self _performOnMainThread:^{ [self applicationRequestsSigningAssertionWithIdentifier:identifier]; }];
        return;
    }
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0 || identifier.length > 128)
        return;
    self.activeSigningIdentifier = [identifier copy];
    [self _aquireApplicationBackgroundAssertion];
    if (self.applicationBackgroundAssertion)
        [self _acquireSigningPowerAssertion];
}

- (void)applicationDidFinishSigningWithIdentifier:(NSString *)identifier {
    if (![NSThread isMainThread]) {
        [self _performOnMainThread:^{ [self applicationDidFinishSigningWithIdentifier:identifier]; }];
        return;
    }
    if (!identifier || ![self.activeSigningIdentifier isEqual:identifier])
        return;
    self.activeSigningIdentifier = nil;
    [self _releaseApplicationBackgroundAssertion];
}

- (void)applicationRequestsSigningAssertion {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf applicationRequestsSigningAssertion];
        }];
        return;
    }

    NSLog(@"*** [reprovisiond] :: applicationRequestsSigningAssertion received.");
    [self _aquireApplicationBackgroundAssertion];
}

- (void)applicationRequestsDebuggingBackgroundSigning {
    NSLog(@"*** [reprovisiond] :: applicationRequestsDebuggingBackgroundSigning recieved.");

    // Start a new background routine now.
    [self _initiateNewSigningRoutine];
}

- (void)applicationRequestsPreferencesUpdate {
    if (![NSThread isMainThread]) {
        __weak RPVDaemonListener *weakSelf = self;
        [self _performOnMainThread:^{
            [weakSelf applicationRequestsPreferencesUpdate];
        }];
        return;
    }

    NSLog(@"*** [reprovisiond] :: applicationRequestsPreferencesUpdate recieved.");

    // Update our internal preferences from NSUserDefaults' shared suite.
    NSTimeInterval oldInterval = [self heartbeatTimerInterval];
    BOOL oldAutomaticResign = [self shouldAutomaticallyResign];
    BOOL oldTrueBackgroundResign = [self trueBgResign];
    [self reloadSettings];
    NSTimeInterval newInterval = [self heartbeatTimerInterval];
    BOOL newAutomaticResign = [self shouldAutomaticallyResign];
    BOOL newTrueBackgroundResign = [self trueBgResign];

    if (!newAutomaticResign) {
        [self.signingTimer invalidate];
        self.signingTimer = nil;
        [self _cancelAllWakeTimer];
        return;
    }

    // Rebuild the timer when any background-signing setting changes.
    if (oldInterval != newInterval ||
        oldAutomaticResign != newAutomaticResign ||
        oldTrueBackgroundResign != newTrueBackgroundResign) {
        NSDate *storedFireDate = [self getPreferenceKey:@"nextFireDate"];
        NSTimeInterval remainingInterval = [storedFireDate timeIntervalSinceDate:[NSDate date]];
        if (oldInterval != newInterval || remainingInterval < 1.0)
            remainingInterval = newInterval;

        [self _restartSigningTimerWithInterval:remainingInterval];
    } else if (!self.signingTimer) {
        [self _restartSigningTimerWithInterval:newInterval];
    }
}

//////////////////////////////////////////////////////////////////////////
// notify.h stuff
//////////////////////////////////////////////////////////////////////////

- (void)setupNotifyPosts {
    int status;

    // Setup notifications for un/locking of the device.
    __weak RPVDaemonListener *weakSelf = self;
    status = notify_register_dispatch("com.apple.springboard.lockstate", &_lockstateToken, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0l), ^(int info) {
        uint64_t state = UINT64_MAX;
        notify_get_state(_lockstateToken, &state);

        if (state == 0) {
            [weakSelf sb_didUIUnlockNotification];
        }
        // else {
        //     [weakSelf sb_didUILockNotification];
        // }
    });

    // SpringBoard boot-up
    status = notify_register_dispatch("SBSpringBoardDidLaunchNotification", &_springboardBootToken, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0l), ^(int token) {
        // No state associated with this message.
        [weakSelf sb_didFinishLaunchingNotification];
    });

    // backboardd backlight changes
    status = notify_register_dispatch("com.apple.backboardd.backlight.changed", &_backboardBacklightChangedToken, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0l), ^(int token) {
        uint64_t state = UINT64_MAX;
        notify_get_state(_backboardBacklightChangedToken, &state);

        [weakSelf bb_backlightChanged:(int)state];
    });
}
@end
