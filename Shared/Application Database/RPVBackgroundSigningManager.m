//
//  RPVBackgroundSigningManager.m
//  iOS
//
//  Created by Matt Clarke on 26/03/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVBackgroundSigningManager.h"

#import "RPVApplicationSigning.h"
#import "RPVApplicationDatabase.h"
#import "RPVResources.h"
#import "RPVNotificationManager.h"

@interface RPVBackgroundSigningManager ()
@property (nonatomic, strong) NSMutableArray *completionHandlers;
@property (nonatomic, readwrite) BOOL signingInProgress;
@end

static NSString *const RPVBackgroundSigningErrorDomain = @"jp.soh.reprovision.background-signing";

typedef NS_ENUM(NSInteger, RPVBackgroundSigningErrorCode) {
    RPVBackgroundSigningDisabled = 1,
    RPVBackgroundSigningMissingCredentials = 2,
};

@implementation RPVBackgroundSigningManager

+ (instancetype)sharedInstance {
    static RPVBackgroundSigningManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        sharedInstance = [[RPVBackgroundSigningManager alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    
    if (self) {
        self.completionHandlers = [NSMutableArray array];
        [[RPVApplicationSigning sharedInstance] addSigningUpdatesObserver:self];
    }
    
    return self;
}

- (void)attemptBackgroundSigningIfNecessary:(void (^)(void))completionHandler {
    [self attemptBackgroundSigningIfNecessaryWithCompletion:^(NSError *error) {
        if (completionHandler)
            completionHandler();
    }];
}

- (void)attemptBackgroundSigningIfNecessaryWithCompletion:(void (^)(NSError *error))completionHandler {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attemptBackgroundSigningIfNecessaryWithCompletion:completionHandler];
        });
        return;
    }

    if (completionHandler)
        [self.completionHandlers addObject:[completionHandler copy]];

    // Coalesce fetch and daemon requests that belong to the same wake.
    if (self.signingInProgress)
        return;

    if (![RPVResources shouldAutomaticallyResign]) {
        NSError *error = [NSError errorWithDomain:RPVBackgroundSigningErrorDomain
                                             code:RPVBackgroundSigningDisabled
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        @"Automatically Re-sign is disabled. Enable it in Settings and run the test again."}];
        [self _finishPendingBackgroundRequestsWithError:error];
        return;
    }

    NSString *teamID = [RPVResources getTeamID];
    NSString *username = [RPVResources getUsername];
    NSString *password = [RPVResources getPassword];
    if (teamID.length == 0 || username.length == 0 || password.length == 0) {
        NSError *error = [NSError errorWithDomain:RPVBackgroundSigningErrorDomain
                                             code:RPVBackgroundSigningMissingCredentials
                                         userInfo:@{NSLocalizedDescriptionKey:
                                                        @"Saved Apple ID credentials are unavailable. Open ReProvision, sign out, and sign in again before testing background signing."}];
        [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"Login Required"
                                                                       body:@"Open ReProvision and sign in again before automatic re-signing can continue."
                                                             isDebugMessage:NO
                                                            isUrgentMessage:YES
                                                        andNotificationID:@"login"];
        [self _finishPendingBackgroundRequestsWithError:error];
        return;
    }

    self.signingInProgress = YES;
    
    [[RPVApplicationSigning sharedInstance] resignApplications:YES
                                        thresholdForExpiration:[RPVResources thresholdForResigning]
                                                    withTeamID:teamID
                                                      username:username
                                                      password:password];
}

- (void)_finishPendingBackgroundRequestsWithError:(NSError *)error {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _finishPendingBackgroundRequestsWithError:error];
        });
        return;
    }

    self.signingInProgress = NO;
    NSArray *handlers = [self.completionHandlers copy];
    [self.completionHandlers removeAllObjects];
    for (void (^handler)(NSError *) in handlers)
        handler(error);
}

- (BOOL)anyApplicationsNeedingResigning {
    NSMutableArray *applications = [NSMutableArray array];
    NSDate *now = [NSDate date];
    NSDate *expirationDate = [now dateByAddingTimeInterval:60 * 60 * 24 * [RPVResources thresholdForResigning]];
    
    [[RPVApplicationDatabase sharedInstance] getApplicationsWithExpiryDateBefore:&applications andAfter:nil date:expirationDate forTeamID:[RPVResources getTeamID]];
    
    return applications.count > 0;
}

//////////////////////////////////////////////////////////////////////////////////
// Application Signing delegate methods.
//////////////////////////////////////////////////////////////////////////////////

- (void)applicationSigningDidStart {
    [[RPVNotificationManager sharedInstance] sendNotificationWithTitle:@"DEBUG" body:@"Attempting background automatic signing" isDebugMessage:YES andNotificationID:nil];
}

- (void)applicationSigningUpdateProgress:(int)progress forBundleIdentifier:(NSString *)bundleIdentifier {}

- (void)applicationSigningDidEncounterError:(NSError *)error forBundleIdentifier:(NSString *)bundleIdentifier {}

- (void)applicationSigningCompleteWithError:(NSError *)error {
    if (self.signingInProgress)
        [self _finishPendingBackgroundRequestsWithError:error];
}

@end
