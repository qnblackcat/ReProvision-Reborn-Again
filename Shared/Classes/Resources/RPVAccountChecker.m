//
//  RPVAccountChecker.m
//  iOS
//
//  Created by Matt Clarke on 07/03/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVAccountChecker.h"
#import "RPVResources.h"
#import "RPVAppID.h"
#import "EEAppleServices.h"
#import "EEBackend.h"

#import <UIKit/UIKit.h>
#import "libMobileGestalt.h"

@implementation RPVAccountChecker

+ (instancetype)sharedInstance {
    static RPVAccountChecker *sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedInstance = [[RPVAccountChecker alloc] init];
    });
    return sharedInstance;
}

// Returns a failure reason, failure code, or team ID array
- (void)checkUsername:(NSString*)username withPassword:(NSString*)password andCompletionHandler:(void (^)(NSString*, NSString*, NSArray*, NSURLCredential*))completionHandler {

    [[EEAppleServices sharedInstance] signInWithUsername:username password:password andCompletionHandler:^(NSError *error, NSDictionary *plist, NSURLCredential *credentials) {

         if (error) {
             completionHandler(error.localizedDescription, @"err", nil,nil);
             return;
         }

         NSString *resultCode = [plist objectForKey:@"reason"];
         NSString *userString = [plist objectForKey:@"userString"];

         if ((!userString || [userString isEqualToString:@""]) && plist) {
             [self _loadTeamsAfterLoginWithResultCode:resultCode
                                           credentials:credentials
                                      remainingRetries:2
                                            completion:completionHandler];
         } else if (plist) {
             completionHandler(userString, resultCode, nil, credentials);
         } else {
             completionHandler(nil, @"err", nil, credentials);
         }
     }];
}

- (void)requestLoginCodeWithCompletionHandler:(void (^)(NSError *error))completion {
    [[EEAppleServices sharedInstance] requestTwoFactorLoginCodeWithCompletionHandler:completion];
}

- (BOOL)hasActiveTwoFactorSession {
    return [[EEAppleServices sharedInstance] hasActiveTwoFactorSession];
}

- (void)_loadTeamsAfterLoginWithResultCode:(NSString *)resultCode
                                credentials:(NSURLCredential *)credentials
                           remainingRetries:(NSUInteger)remainingRetries
                                 completion:(void (^)(NSString*, NSString*, NSArray*, NSURLCredential*))completionHandler {
    [[EEAppleServices sharedInstance] listTeamsWithCredentials:credentials completionHandler:^(NSError *error, NSDictionary *plist) {
        NSArray *teams = [plist[@"teams"] isKindOfClass:[NSArray class]] ? plist[@"teams"] : nil;
        NSString *portalMessage = [plist[@"userString"] isKindOfClass:[NSString class]] ? plist[@"userString"] : nil;
        id portalCode = plist[@"resultCode"];
        BOOL invalidPortalCode = portalCode && (![portalCode respondsToSelector:@selector(integerValue)] || [portalCode integerValue] != 0);
        BOOL portalFailure = error || !teams || invalidPortalCode || (teams.count == 0 && portalMessage.length > 0);
        if (portalFailure && remainingRetries > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self _loadTeamsAfterLoginWithResultCode:resultCode
                                              credentials:credentials
                                         remainingRetries:remainingRetries - 1
                                               completion:completionHandler];
            });
            return;
        }

        if (portalFailure) {
            NSString *failureReason = error.localizedDescription;
            if (failureReason.length == 0) {
                failureReason = portalMessage;
            }
            if (failureReason.length == 0) {
                failureReason = @"The Developer account could not be loaded.";
            }
            // GrandSlam succeeded; this failure is in Developer Services.
            failureReason = [NSString stringWithFormat:@"Apple sign-in completed, but Developer account setup failed: %@", failureReason];
            completionHandler(failureReason, @"err", nil, nil);
            return;
        }

        if (teams.count == 0) {
            completionHandler(@"Please accept the Apple Developer terms at https://developer.apple.com",
                              resultCode, teams, nil);
            return;
        }

        completionHandler([plist objectForKey:@"userString"], resultCode, teams, credentials);
    }];
}

- (void)validateLoginCode:(NSString*)code withCompletionHandler:(void (^)(NSString*, NSString*, NSArray*, NSURLCredential*))completionHandler {
    [[EEAppleServices sharedInstance] validateLoginCode:code andCompletionHandler:^(NSError *error, NSDictionary *plist, NSURLCredential *credentials) {

         if (error) {
             completionHandler(error.localizedDescription, @"err", nil,nil);
             return;
         }

         NSString *resultCode = [plist objectForKey:@"reason"];
         NSString *userString = [plist objectForKey:@"userString"];

         if ((!userString || [userString isEqualToString:@""]) && plist) {
             // Retry the read-only lookup because the 2FA session is already consumed.
             [self _loadTeamsAfterLoginWithResultCode:resultCode
                                           credentials:credentials
                                      remainingRetries:2
                                            completion:completionHandler];
         } else if (plist) {
             completionHandler(userString, resultCode, nil, credentials);
         } else {
             completionHandler(nil, @"err", nil, credentials);
         }
     }];
}

- (void)request2FAFallbackWithCompletionHandler:(void (^)(NSString*, NSString*, NSArray*, NSURLCredential*))completionHandler {
    [[EEAppleServices sharedInstance] fallback2FACodeRequest:^(NSError *error, NSDictionary *plist, NSURLCredential *credentials) {

         if (error) {
             completionHandler(error.localizedDescription, @"err", nil,nil);
             return;
         }

         NSString *resultCode = [plist objectForKey:@"reason"];
         NSString *userString = [plist objectForKey:@"userString"];

         if ((!userString || [userString isEqualToString:@""]) && plist) {
             [self _loadTeamsAfterLoginWithResultCode:resultCode
                                           credentials:credentials
                                      remainingRetries:2
                                            completion:completionHandler];
         } else if (plist) {
             completionHandler(userString, resultCode, nil, credentials);
         } else {
             completionHandler(nil, @"err", nil, credentials);
         }
     }];
}

- (NSString*)nameForCurrentDevice {
    return [[UIDevice currentDevice] name];
}

- (NSString*)UDIDForCurrentDevice {
    CFStringRef udid = (CFStringRef)MGCopyAnswer(kMGUniqueDeviceID);
    return (__bridge NSString*)udid;
}

- (EESystemType)platformTypeForCurrentDevice {
#if TARGET_OS_IOS
    return EESystemTypeiOS;
#elif TARGET_OS_WATCHOS
    return EESystemTypewatchOS;
#elif TARGET_OS_TV
    return EESystemTypetvOS;
#endif
}

- (void)registerCurrentDeviceForTeamID:(NSString*)teamID withIdentity:(NSString*)identity gsToken:(NSString*)gsToken andCompletionHandler:(void (^)(NSError*))completionHandler {

    [EEBackend provisionDevice:[self UDIDForCurrentDevice] name:[self nameForCurrentDevice] identity:identity gsToken:gsToken priorChosenTeamID:teamID systemType:[self platformTypeForCurrentDevice] withCallback:^(NSError *error) {
         completionHandler(error);
     }];
}

- (void)registerCurrentWatchForTeamID:(NSString*)teamID withIdentity:(NSString*)identity gsToken:(NSString*)gsToken andCompletionHandler:(void (^)(NSError*))completionHandler {

    [EEBackend provisionDevice:[RPVResources activePairedWatchUDID] name:[RPVResources activePairedWatchName] identity:identity gsToken:gsToken priorChosenTeamID:teamID systemType:EESystemTypewatchOS withCallback:^(NSError *error) {
         completionHandler(error);
     }];
}

- (void)listAllApplicationsWithCompletionHandler:(void (^)(NSError*, NSArray *))completionHandler {
    if(![RPVResources getUsername] || ![RPVResources getPassword] || ![RPVResources getTeamID]) {
        // username, password or teamID is nil
        completionHandler(nil, nil);
        return;
    }

    [[EEAppleServices sharedInstance] ensureSessionWithIdentity:[RPVResources getUsername] gsToken:[RPVResources getPassword] andCompletionHandler:^(NSError *error, NSDictionary *plist) {
         if(!error && plist) {
             [[EEAppleServices sharedInstance] listAllApplicationsForTeamID:[RPVResources getTeamID] systemType:[self platformTypeForCurrentDevice] withCompletionHandler:^(NSError *error, NSDictionary *dict) {
                  // dictionary -> array of RPVAppID
                  NSMutableArray *appIds = [NSMutableArray array];
                  if(!error && dict) {
                      for (NSDictionary* apps in dict[@"appIds"]) {
                          RPVAppID *appId = [[RPVAppID alloc] initWithDictionary:apps];
                          [appIds addObject:appId];
                      }
                      completionHandler(nil, [appIds copy]);
                  } else completionHandler(error, nil);
              }];
         } else {
             completionHandler(error, nil);
         }
     }];

}

@end
