#!/usr/bin/env ruby
require 'tmpdir'
root = File.expand_path('../..', __dir__)
daemon = File.read(ARGV[0] || File.join(root, 'Shared/Daemon/RPVDaemonListener.m'))
app = File.read(ARGV[1] || File.join(root, 'iOS/AppDelegate.m'))
def extract(source, names)
  names.map do |name|
    start = source.index(/^\- \([^\n]+\)#{name}\b/)
    abort "Missing production method #{name}" unless start
    source[start..source.index(/^\}/, start)]
  end.join("\n")
end
Dir.mktmpdir('repro-locked-tests-') do |dir|
  File.write(File.join(dir, 'Daemon.inc'), extract(daemon, %w[_performOnMainThread _aquireApplicationBackgroundAssertion
    _acquireSigningPowerAssertion _releaseApplicationBackgroundAssertion _assertionFallbackDidFire
    applicationDidFinishTask applicationRequestsSigningAssertionWithIdentifier applicationDidFinishSigningWithIdentifier applicationDidLaunch]))
  File.write(File.join(dir, 'App.inc'), extract(app, %w[_notifyDaemonOfMessageHandled applicationSigningDidStart applicationSigningCompleteWithError]))
  File.write(File.join(dir, 'main.m'), <<~'OBJC')
    #import <Foundation/Foundation.h>
    #import <IOKit/pwr_mgt/IOPMLib.h>
    #define TARGET_OS_SIMULATOR 0
    #define APPLICATION_IDENTIFIER "jp.soh.reprovision.ios"
    #define BKSProcessAssertionFlagPreventSuspend 1
    #define BKSProcessAssertionFlagAllowIdleSleep 4
    #define BKSProcessAssertionReasonFinishTask 4
    // Foundation can load the host's real AssertionServices. Never shadow its
    // Objective-C runtime class; the extracted code uses this explicit fixture.
    #define BKSProcessAssertion RPVFixtureProcessAssertion
    #define RPVErrorAlreadyUndertakingPipeline 100
    #define RPVErrorNoSigningRequired 101
    static const NSTimeInterval RPVSigningAssertionFallbackInterval = 300;
    typedef NS_ENUM(NSUInteger, RPVApplicationNotification) { kNewSigningRoutine, kCheckForCredentials, kShowQueuedUpdate };
    #define CHECK(c,m) do { if (!(c)) { fprintf(stderr,"FAIL %s\n",m); exit(1); } else printf("PASS %s\n",m); } while(0)
    static pid_t appPID = 123;
    static NSUInteger creates, releases, finishes;
    static NSMutableArray *assertions;
    static NSDictionary *lastPowerProperties;
    static BOOL powerFailure;
    BOOL SBSProcessIDForDisplayIdentifier(CFStringRef identifier, pid_t *pid) { *pid = appPID; return YES; }
    IOReturn IOPMAssertionCreateWithProperties(CFDictionaryRef properties, IOPMAssertionID *assertion) {
      lastPowerProperties = [(__bridge NSDictionary *)properties copy];
      if (powerFailure) return kIOReturnNotPermitted;
      *assertion = (IOPMAssertionID)++creates; return kIOReturnSuccess;
    }
    IOReturn IOPMAssertionRelease(IOPMAssertionID assertion) { ++releases; return kIOReturnSuccess; }
    @interface NSObject (RemoteMessages)
    - (void)daemonDidRequestNewBackgroundSigning;
    - (void)daemonDidRequestCredentialsCheck;
    - (void)daemonDidRequestQueuedNotification;
    @end
    @interface BKSProcessAssertion : NSObject
    @property(copy) void (^handler)(BOOL);
    @property BOOL invalidated;
    @property pid_t pid;
    - (id)initWithPID:(pid_t)pid flags:(unsigned int)flags reason:(int)reason name:(NSString *)name withHandler:(void (^)(BOOL))handler;
    - (void)invalidate;
    @end
    @implementation BKSProcessAssertion
    - (id)initWithPID:(pid_t)pid flags:(unsigned int)flags reason:(int)reason name:(NSString *)name withHandler:(void (^)(BOOL))handler {
      if ((self = [super init])) { self.pid=pid; self.handler=handler; [assertions addObject:self]; handler(YES); }
      return self;
    }
    - (void)invalidate { self.invalidated=YES; }
    @end
    @interface RPVDaemonListener : NSObject
    @property(strong) BKSProcessAssertion *applicationBackgroundAssertion;
    @property pid_t applicationAssertionPID;
    @property NSUInteger applicationAssertionGeneration;
    @property IOPMAssertionID signingPowerAssertion;
    @property(copy) NSString *activeSigningIdentifier;
    @property(strong) NSTimer *assertionFallbackTimer;
    @property(strong) NSTimer *applicationLaunchRetryTimer;
    @property NSUInteger applicationLaunchRetryAttempt;
    @property(strong) NSMutableArray *pendingXpcConnectionQueue;
    @property(strong) id xpcConnection;
    @end
    @implementation RPVDaemonListener
    #include "Daemon.inc"
    @end
    @interface FakeConnection : NSObject
    @property(strong) RPVDaemonListener *daemon;
    @end
    @implementation FakeConnection
    - (id)remoteObjectProxy { return self; }
    - (void)applicationDidFinishTask { ++finishes; [self.daemon applicationDidFinishTask]; }
    - (void)applicationDidFinishSigningWithIdentifier:(NSString *)identifier { [self.daemon applicationDidFinishSigningWithIdentifier:identifier]; }
    @end
    @interface RPVNotificationManager : NSObject
    + (instancetype)sharedInstance;
    - (void)sendNotificationWithTitle:(NSString *)title body:(NSString *)body isDebugMessage:(BOOL)debug isUrgentMessage:(BOOL)urgent andNotificationID:(NSString *)identifier;
    @end
    @implementation RPVNotificationManager
    + (instancetype)sharedInstance { static id manager; if (!manager) manager=[self new]; return manager; }
    - (void)sendNotificationWithTitle:(NSString *)title body:(NSString *)body isDebugMessage:(BOOL)debug isUrgentMessage:(BOOL)urgent andNotificationID:(NSString *)identifier {}
    @end
    @interface AppProbe : NSObject
    @property BOOL signingAssertionRequested;
    @property BOOL applicationSigningReportedPerAppError;
    @property(copy) NSString *signingAssertionIdentifier;
    @property(strong) id daemonConnection;
    @end
    @implementation AppProbe
    - (void)_requestSigningAssertionFromDaemon {
      [[self.daemonConnection daemon] applicationRequestsSigningAssertionWithIdentifier:self.signingAssertionIdentifier];
    }
    #include "App.inc"
    @end
    static void Drain(void) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; }
    int main(void) { @autoreleasepool {
      assertions=NSMutableArray.new;
      RPVDaemonListener *daemon=[RPVDaemonListener new];
      FakeConnection *connection=[FakeConnection new]; connection.daemon=daemon;
      AppProbe *app=[AppProbe new]; app.daemonConnection=connection;
      app.signingAssertionRequested=YES;
      [app _notifyDaemonOfMessageHandled];
      CHECK(finishes==0,"UIKit expiration / unrelated completion cannot release active signing");
      [daemon applicationRequestsSigningAssertionWithIdentifier:@"pass-A"];
      Drain();
      BKSProcessAssertion *first=daemon.applicationBackgroundAssertion;
      CHECK(first && !first.invalidated,"active pass acquires process assertion");
      CHECK(creates==1 && daemon.signingPowerAssertion!=0,"active pass acquires system-sleep assertion");
      CHECK([lastPowerProperties[(__bridge NSString *)kIOPMAssertionTypeKey] isEqual:(__bridge NSString *)kIOPMAssertionTypePreventUserIdleSystemSleep],"power assertion does not request display wake");
      CHECK([lastPowerProperties[(__bridge NSString *)kIOPMAssertionTimeoutKey] doubleValue]==300,"power assertion has five-minute safety timeout");
      CHECK([lastPowerProperties[(__bridge NSString *)kIOPMAssertionTimeoutActionKey] isEqual:(__bridge NSString *)kIOPMAssertionTimeoutActionTurnOff],"powerd independently turns assertion off on timeout");
      [daemon applicationDidFinishTask];
      CHECK(daemon.applicationBackgroundAssertion==first && !first.invalidated,"daemon also rejects generic completion during signing");
      [daemon applicationDidLaunch];
      CHECK(daemon.applicationBackgroundAssertion==first,"XPC reconnect with empty queue preserves active pass");
      [daemon applicationRequestsSigningAssertionWithIdentifier:@"pass-A"];
      CHECK(creates==1 && assertions.count==1,"reconnect does not duplicate assertions");
      [daemon applicationDidFinishSigningWithIdentifier:@"old-pass"];
      CHECK(!first.invalidated,"stale pass completion cannot release current pass");
      [daemon applicationDidFinishSigningWithIdentifier:@"pass-A"];
      CHECK(first.invalidated && !daemon.applicationBackgroundAssertion && daemon.signingPowerAssertion==0 && releases==1,"matching completion releases both assertions");
      [daemon applicationDidFinishSigningWithIdentifier:@"pass-A"];
      CHECK(releases==1,"duplicate completion is harmless");
      [daemon applicationRequestsSigningAssertionWithIdentifier:@"pass-B"];
      Drain();
      BKSProcessAssertion *second=daemon.applicationBackgroundAssertion;
      first.handler(NO); Drain();
      CHECK(daemon.applicationBackgroundAssertion==second && !second.invalidated,"late failure from old assertion cannot clear new assertion");
      appPID=456;
      [daemon applicationRequestsSigningAssertionWithIdentifier:@"pass-B"];
      Drain();
      CHECK(second.invalidated && daemon.applicationAssertionPID==456 && daemon.applicationBackgroundAssertion.pid==456,"restarted app gets assertion for new PID");
      [daemon _assertionFallbackDidFire:nil];
      CHECK(!daemon.activeSigningIdentifier && !daemon.applicationBackgroundAssertion && daemon.signingPowerAssertion==0,"watchdog releases hung pass and power assertion");
      app.signingAssertionRequested=NO;
      [app _notifyDaemonOfMessageHandled];
      CHECK(finishes==1,"idle generic completion still forwarded");
      appPID=0;
      [daemon applicationRequestsSigningAssertionWithIdentifier:@"pass-C"];
      CHECK(!daemon.applicationBackgroundAssertion && daemon.signingPowerAssertion==0,"no PID does not take power assertion");
      [daemon applicationDidFinishSigningWithIdentifier:@"pass-C"];
      appPID=789; powerFailure=YES;
      [daemon applicationRequestsSigningAssertionWithIdentifier:@"pass-D"];
      Drain();
      CHECK(daemon.applicationBackgroundAssertion && !daemon.signingPowerAssertion,"power assertion denial is handled without crashing");
      [daemon applicationDidFinishSigningWithIdentifier:@"pass-D"];
      CHECK(!daemon.applicationBackgroundAssertion,"denied power assertion still allows cleanup");
      [daemon applicationRequestsSigningAssertionWithIdentifier:@""];
      CHECK(!daemon.activeSigningIdentifier,"invalid signing identifier rejected");
      powerFailure=NO;
      [app applicationSigningDidStart]; Drain();
      NSString *identifier=app.signingAssertionIdentifier;
      CHECK(identifier.length>0 && [daemon.activeSigningIdentifier isEqual:identifier],"real signing-start observer acquires identified lease");
      [app applicationSigningDidStart];
      CHECK([app.signingAssertionIdentifier isEqual:identifier],"duplicate start does not replace active lease");
      [app applicationSigningCompleteWithError:[NSError errorWithDomain:@"fixture" code:100 userInfo:nil]];
      CHECK(app.signingAssertionRequested && [daemon.activeSigningIdentifier isEqual:identifier],"busy response does not finish existing signing pass");
      [app applicationSigningCompleteWithError:nil];
      CHECK(!app.signingAssertionRequested && !app.signingAssertionIdentifier && !daemon.activeSigningIdentifier && !daemon.applicationBackgroundAssertion,"real successful completion clears the matching lease");
      [app applicationSigningDidStart]; Drain();
      [app applicationSigningCompleteWithError:[NSError errorWithDomain:@"fixture" code:101 userInfo:nil]];
      CHECK(!daemon.applicationBackgroundAssertion && !app.signingAssertionRequested,"no-signing-needed path also cleans up");
      return 0;
    } }
  OBJC
  binary=File.join(dir,'locked-tests')
  abort 'Compile failed' unless system('xcrun','--sdk','macosx','clang','-fobjc-arc','-fblocks','-Wno-objc-method-access','-Wno-incompatible-pointer-types',
    '-I',dir,File.join(dir,'main.m'),'-framework','Foundation','-o',binary)
  abort 'Locked signing tests failed' unless system(binary)
end
