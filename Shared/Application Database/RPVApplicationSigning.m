//
//  RPVApplicationSigning.m
//  iOS
//
//  Created by Matt Clarke on 09/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVApplicationSigning.h"
#import "EEBackend.h"
#import "RPVApplication.h"
#import "RPVApplicationDatabase.h"

#import "SSZipArchive.h"
#import <dlfcn.h>

/* Private headers */
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)arg1 withOptions:(NSDictionary *)arg2 error:(NSError **)arg3;
- (NSArray *)allApplications;
- (BOOL)uninstallApplication:(id)arg1 withOptions:(id)arg2;
@end

// Load the iOS 26 installation API dynamically to preserve older-system support.
@protocol RPVMIInstallOptions <NSObject>
- (void)setInstallTargetType:(NSUInteger)installTargetType;
- (void)setAllowLocalProvisioned:(BOOL)allowLocalProvisioned;
- (void)setDeveloperInstall:(BOOL)developerInstall;
- (void)setUserInitiated:(BOOL)userInitiated;
- (void)setBundleIdentifier:(NSString *)bundleIdentifier;
@end

@interface NSObject (RPVInstallCoordination)
+ (void)installApplication:(NSURL *)applicationURL
                   options:(id<RPVMIInstallOptions>)options
                completion:(void (^)(id identity, NSError *error))completion;
+ (BOOL)uninstallAppWithBundleID:(NSString *)bundleIdentifier error:(NSError **)error;
@end


@interface RPVApplicationSigning ()

@property (nonatomic, strong) NSMutableArray *installQueue;
@property (nonatomic, readwrite) BOOL undertakingResignPipeline;
@property (nonatomic, readwrite) UIBackgroundTaskIdentifier currentBackgroundTaskIdentifier;

@property (nonatomic, strong) NSMutableArray *observers;

@end

static RPVApplicationSigning *sharedInstance;

@implementation RPVApplicationSigning

+ (instancetype)sharedInstance {
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        sharedInstance = [[self alloc] init];
    });

    return sharedInstance;
}

- (instancetype)init {
    self = [super init];

    if (self) {
        self.observers = [NSMutableArray array];
    }

    return self;
}

- (void)addSigningUpdatesObserver:(id<RPVApplicationSigningProtocol>)observer {
    [self.observers addObject:observer];
}

- (void)removeSigningUpdatesObserver:(id<RPVApplicationSigningProtocol>)observer {
    [self.observers removeObject:observer];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)_resignApplicationsArray:(NSArray *)applications withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningDidStart];
        }

        if (self.undertakingResignPipeline) {
            NSError *error = [self _errorFromString:@"Already undertaking the re-sign pipeline!" errorCode:RPVErrorAlreadyUndertakingPipeline];

            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        } else {
            self.undertakingResignPipeline = YES;
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 1. Do pre-flight checks.
        //////////////////////////////////////////////////////////////////////////////////////

        // TODO: Network connectivity.

        // Update install queue with new applications list
        self.installQueue = [applications mutableCopy];

        //////////////////////////////////////////////////////////////////////////////////////
        // 2. Initiate signing for applications if applicable.
        //////////////////////////////////////////////////////////////////////////////////////

        // If no signing needed, just exit.
        if (self.installQueue.count == 0) {
            self.undertakingResignPipeline = NO;
            NSError *error = [self _errorFromString:@"No applications need re-signing" errorCode:RPVErrorNoSigningRequired];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        }

        // Move to a background task!
        UIApplication *application = [UIApplication sharedApplication];
        UIBackgroundTaskIdentifier __block bgTask = [application beginBackgroundTaskWithName:@"ReProvision Application Signing" expirationHandler:^{
            // Clean up any unfinished task business by marking where you
            // stopped or ending the task outright.

            [application endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }];

        self.currentBackgroundTaskIdentifier = bgTask;

        // Update progress handler to 0% for all applications.
        for (RPVApplication *app in [self.installQueue reverseObjectEnumerator]) {
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningUpdateProgress:0 forBundleIdentifier:app.bundleIdentifier];
            }
        }

        // Start signing.
        [self _initiateNextInstallFromQueueWithTeamID:teamID
                                             username:username
                                             password:password];
    });
}

- (void)resignSpecificApplications:(NSArray *)applications withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    [self _resignApplicationsArray:applications withTeamID:teamID username:username password:password];
}

- (void)resignApplications:(BOOL)onlyExpiringApplications thresholdForExpiration:(int)thresholdForExpiration withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    //////////////////////////////////////////////////////////////////////////////////////
    // 0. Iterate over all the applications available in RPVApplicationDatabase.
    //////////////////////////////////////////////////////////////////////////////////////

    // Get list of applications from RPVApplicationDatabase
    NSMutableArray *applications = [NSMutableArray array];
    if (onlyExpiringApplications) {
        NSDate *now = [NSDate date];
        NSDate *expirationDate = [now dateByAddingTimeInterval:60 * 60 * 24 * thresholdForExpiration];

        if (![[RPVApplicationDatabase sharedInstance] getApplicationsWithExpiryDateBefore:&applications andAfter:nil date:expirationDate forTeamID:teamID]) {
            // sad times.
            self.undertakingResignPipeline = NO;
            NSError *error = [self _errorFromString:@"Failed to get applications within expiry date" errorCode:-1337];
            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:error];
            }
            return;
        }
    } else {
        applications = [[[RPVApplicationDatabase sharedInstance] getAllApplicationsForTeamID:teamID] mutableCopy];
    }

    [self _resignApplicationsArray:applications withTeamID:teamID username:username password:password];
}

/**
 For the given RPVApplication, this method copies its .app bundle into a directory structure of
 an extracted IPA, in a temporary directory.

 @param extractedArchiveURL Output URL of where the root directory structure is located
 @param applicationBundleURL Output URL of where the application's bundle is located
 @param error If non-null, any arising error.
 @return Success
 */
- (BOOL)_copyApplicationBundleForApplication:(RPVApplication *)application extractedArchiveURL:(NSURL **)extractedArchiveURL applicationBundleURL:(NSURL **)applicationBundleURL error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *operationDirectory = [[EEBackend applicationTemporaryDirectory] stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"reprovision-staging-%@", [[NSUUID UUID] UUIDString]]];
    NSString *payloadDirectory = [operationDirectory stringByAppendingPathComponent:@"Payload"];
    NSString *dotAppName = nil;
    NSError *filesystemError = nil;

    if (![fileManager createDirectoryAtPath:operationDirectory
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&filesystemError]) {
        if (error) {
            NSString *description = filesystemError.localizedDescription ?: @"Failed to create a clean signing workspace.";
            *error = [self _errorFromString:description errorCode:RPVErrorFailedToCopyBundle];
        }
        return NO;
    }

    if ([application.class isEqual:[RPVApplication class]]) {
        NSString *applicationBundleLocation = [application locationOfApplicationOnFilesystem].path;
        dotAppName = [applicationBundleLocation lastPathComponent];

        if (![fileManager createDirectoryAtPath:payloadDirectory
                    withIntermediateDirectories:YES
                                     attributes:nil
                                          error:&filesystemError]) {
            [fileManager removeItemAtPath:operationDirectory error:nil];
            if (error) {
                NSString *description = filesystemError.localizedDescription ?: @"Failed to create the IPA Payload directory.";
                *error = [self _errorFromString:description errorCode:RPVErrorFailedToCopyBundle];
            }
            return NO;
        }

        NSString *destinationPath = [payloadDirectory stringByAppendingPathComponent:dotAppName];
        if (![fileManager copyItemAtPath:applicationBundleLocation toPath:destinationPath error:&filesystemError]) {
            [fileManager removeItemAtPath:operationDirectory error:nil];
            if (error) {
                NSString *description = filesystemError.localizedDescription ?: @"Failed to copy the application bundle.";
                *error = [self _errorFromString:description errorCode:RPVErrorFailedToCopyBundle];
            }
            return NO;
        }

    } else {
        // This is an IPA application, therefore -locationOfApplicationOnFilesystem will return the .ipa
        // file on the filesystem.

        // Use a clean extraction directory for each operation.
        BOOL success = [SSZipArchive unzipFileAtPath:[application locationOfApplicationOnFilesystem].path
                                       toDestination:operationDirectory
                                           overwrite:YES
                                            password:nil
                                               error:&filesystemError];

        if (!success) {
            [fileManager removeItemAtPath:operationDirectory error:nil];
            if (error) {
                NSString *description = filesystemError.localizedDescription ?: @"Failed to unpack the IPA.";
                *error = [self _errorFromString:description errorCode:RPVErrorFailedToCopyBundle];
            }
            return NO;
        }
    }

    NSArray *payloadContents = [fileManager contentsOfDirectoryAtPath:payloadDirectory error:&filesystemError];
    if (!payloadContents) {
        [fileManager removeItemAtPath:operationDirectory error:nil];
        if (error) {
            NSString *description = filesystemError.localizedDescription ?: @"The IPA does not contain a readable Payload directory.";
            *error = [self _errorFromString:description errorCode:RPVErrorFailedToCopyBundle];
        }
        return NO;
    }

    NSMutableArray *topLevelApplications = [NSMutableArray array];
    for (NSString *entry in payloadContents) {
        NSString *candidatePath = [payloadDirectory stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if ([[entry pathExtension] caseInsensitiveCompare:@"app"] == NSOrderedSame &&
            [fileManager fileExistsAtPath:candidatePath isDirectory:&isDirectory] && isDirectory) {
            [topLevelApplications addObject:entry];
        }
    }

    if (topLevelApplications.count != 1) {
        NSString *description = nil;
        if (topLevelApplications.count == 0) {
            description = @"The IPA Payload does not contain a top-level .app bundle.";
        } else {
            description = [NSString stringWithFormat:
                           @"The IPA Payload contains multiple top-level .app bundles (%@). ReProvision stopped before installation.",
                           [topLevelApplications componentsJoinedByString:@", "]];
        }
        [fileManager removeItemAtPath:operationDirectory error:nil];
        if (error) {
            *error = [self _errorFromString:description errorCode:RPVErrorFailedToCopyBundle];
        }
        return NO;
    }

    dotAppName = [topLevelApplications firstObject];

    if (![application.class isEqual:[RPVApplication class]]) {
        NSError *cacheClearError = nil;
        [fileManager removeItemAtPath:[application locationOfApplicationOnFilesystem].path error:&cacheClearError];
        if (cacheClearError) {
            NSLog(@"Failed to remove '%@': %@", [application locationOfApplicationOnFilesystem].path, cacheClearError);
        }
    }

    *extractedArchiveURL = [NSURL fileURLWithPath:operationDirectory];
    *applicationBundleURL = [NSURL fileURLWithPath:[payloadDirectory stringByAppendingPathComponent:dotAppName]];

    return YES;
}

- (NSError *)_errorFromString:(NSString *)string errorCode:(int)code {
    NSDictionary *userInfo = @{
        NSLocalizedDescriptionKey: NSLocalizedString(string, nil),
        NSLocalizedFailureReasonErrorKey: NSLocalizedString(string, nil),
        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString(@"", nil)
    };

    NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:code
                                     userInfo:userInfo];

    return error;
}

- (void)_initiateNextInstallFromQueueWithTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    if ([self.installQueue count] == 0) {
        // We can exit now.
        self.undertakingResignPipeline = NO;
    } else {
        // Pull next off the front of the array.
        RPVApplication *application = [self.installQueue firstObject];

        [self _resignApplication:application
                      withTeamID:teamID
                        username:username
                        password:password];
    }
}

- (void)_installIpaAtPath:(NSString *)ipaPath
 originalBundleIdentifier:(NSString *)originalBundleIdentifier
   signedBundleIdentifier:(NSString *)signedBundleIdentifier
replaceOriginalAfterSuccess:(BOOL)replaceOriginalAfterSuccess
                completion:(void (^)(NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *ipaURL = [NSURL fileURLWithPath:ipaPath];
        NSLog(@"Does ipaPath exist? %d", [[NSFileManager defaultManager] fileExistsAtPath:ipaPath]);

        void (^finishInstallation)(BOOL, NSError *) = ^(BOOL result, NSError *error) {
            // Keep the installed copy if its replacement fails.
            NSError *installationError = nil;
            if (!result) {
                NSString *description = error.localizedDescription;
                if (description.length == 0) {
                    description = @"The installer rejected the signed IPA without returning an error.";
                }

                NSString *errorMessage = nil;
                if ([description localizedCaseInsensitiveContainsString:@"invalid entitlements"]) {
                    errorMessage = [NSString stringWithFormat:
                                    @"Incorrect entitlements for this application. ReProvision may not support a capability it needs.\n\nInstaller: %@ (%@, code %ld)",
                                    description, error.domain ?: @"unknown domain", (long)error.code];
                } else if ([description localizedCaseInsensitiveContainsString:@"valid provisioning profile"]) {
                    errorMessage = [NSString stringWithFormat:
                                    @"This application was not signed with a provisioning profile valid for this device. Try signing out and back in, then sign it again.\n\nInstaller: %@ (%@, code %ld)",
                                    description, error.domain ?: @"unknown domain", (long)error.code];
                } else if (error.code == 13) {
                    errorMessage = [NSString stringWithFormat:
                                    @"This app could not be installed because the account's active signed-app limit was reached.\n\nInstaller: %@ (%@, code %ld)",
                                    description, error.domain ?: @"unknown domain", (long)error.code];
                } else {
                    errorMessage = [NSString stringWithFormat:@"%@\n\nInstaller: %@ (code %ld)",
                                    description, error.domain ?: @"unknown domain", (long)error.code];
                }

                if (![originalBundleIdentifier isEqualToString:signedBundleIdentifier]) {
                    errorMessage = [errorMessage stringByAppendingFormat:
                                    @"\nOriginal bundle ID: %@\nSigned bundle ID: %@",
                                    originalBundleIdentifier, signedBundleIdentifier];
                }
                installationError = [self _errorFromString:errorMessage errorCode:RPVErrorFailedToInstallSignedIPA];
            }

            if (result) {
                for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                    [observer applicationSigningUpdateProgress:90 forBundleIdentifier:originalBundleIdentifier];
                }

                // Remove the old bundle ID only after the replacement succeeds.
                if (replaceOriginalAfterSuccess &&
                    ![originalBundleIdentifier isEqualToString:signedBundleIdentifier]) {
                    BOOL removedOriginal = NO;
                    NSError *removalError = nil;
                    NSOperatingSystemVersion iOS26 = {26, 0, 0};
                    Class coordinatorClass = NSClassFromString(@"IXAppInstallCoordinator");
                    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:iOS26] &&
                        [coordinatorClass respondsToSelector:@selector(uninstallAppWithBundleID:error:)]) {
                        removedOriginal = [coordinatorClass uninstallAppWithBundleID:originalBundleIdentifier
                                                                               error:&removalError];
                    } else {
                        removedOriginal = [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:originalBundleIdentifier
                                                                                                  withOptions:nil];
                    }
                    if (!removedOriginal) {
                        NSLog(@"Replacement '%@' installed, but the old application '%@' could not be removed: %@",
                              signedBundleIdentifier, originalBundleIdentifier, removalError);
                    }
                }

                for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                    [observer applicationSigningUpdateProgress:100 forBundleIdentifier:originalBundleIdentifier];
                }
            }

            // Legacy installs and early failures still require explicit cleanup.
            [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
            if (completion) {
                completion(installationError);
            }
        };

        NSOperatingSystemVersion iOS26 = {26, 0, 0};
        if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:iOS26]) {
            dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/InstallCoordination.framework/InstallCoordination", RTLD_NOW);

            Class optionsClass = NSClassFromString(@"MIInstallOptions");
            Class coordinatorClass = NSClassFromString(@"IXAppInstallCoordinator");
            if (!optionsClass ||
                ![coordinatorClass respondsToSelector:@selector(installApplication:options:completion:)]) {
                NSError *unsupported = [self _errorFromString:
                                        @"The iOS 26 installation service is unavailable on this device."
                                                          errorCode:RPVErrorFailedToInstallSignedIPA];
                finishInstallation(NO, unsupported);
                return;
            }

            id<RPVMIInstallOptions> options = [[optionsClass alloc] init];
            [options setInstallTargetType:1]; // user application
            [options setAllowLocalProvisioned:YES];
            [options setDeveloperInstall:YES];
            [options setUserInitiated:YES];
            [options setBundleIdentifier:signedBundleIdentifier];

            [coordinatorClass installApplication:ipaURL
                                         options:options
                                      completion:^(id identity, NSError *installError) {
                finishInstallation(installError == nil, installError);
            }];
            return;
        }

        NSError *error = nil;
        NSDictionary *options = @{ @"CFBundleIdentifier": signedBundleIdentifier,
                                   @"AllowInstallLocalProvisioned": @YES };
        BOOL result = NO;
        @try {
            result = [[LSApplicationWorkspace defaultWorkspace] installApplication:ipaURL
                                                                       withOptions:options
                                                                             error:&error];
        } @catch (NSException *exception) {
            NSString *description = exception.reason ?: exception.description ?: @"The installer raised an unknown exception.";
            error = [self _errorFromString:description errorCode:RPVErrorFailedToInstallSignedIPA];
        }
        finishInstallation(result, error);
    });
}

- (void)_resignApplication:(RPVApplication *)application withTeamID:(NSString *)teamID username:(NSString *)username password:(NSString *)password {
    NSString *originalBundleIdentifier = [[application bundleIdentifier] copy] ?: @"";
    BOOL replacesInstalledApplication = [application.class isEqual:[RPVApplication class]];

    // Update progress to 10% for this application.
    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
        [observer applicationSigningUpdateProgress:10 forBundleIdentifier:originalBundleIdentifier];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // 1. Make a copy of this application's .app into a directory structure of an IPA.
    //////////////////////////////////////////////////////////////////////////////////////

    NSURL *extractedArchiveURL = nil;   // This root directory is repacked into an IPA.
    NSURL *applicationBundleURL = nil;  // Passed to EEbackend to sign (the .app).
    NSError *error = nil;

    void (^finishCurrentApplicationWithError)(NSError *) = ^(NSError *pipelineError) {
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningDidEncounterError:pipelineError forBundleIdentifier:originalBundleIdentifier];
        }

        if (self.installQueue.count > 1) {
            [self.installQueue removeObjectAtIndex:0];
            [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                 username:username
                                                 password:password];
        } else {
            [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
            self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;
            self.undertakingResignPipeline = NO;

            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:pipelineError];
            }
        }
    };

    void (^finishCurrentApplicationSuccessfully)(void) = ^{
        if (self.installQueue.count > 0) {
            [self.installQueue removeObjectAtIndex:0];
        }

        if (self.installQueue.count > 0) {
            [self _initiateNextInstallFromQueueWithTeamID:teamID
                                                 username:username
                                                 password:password];
        } else {
            [[UIApplication sharedApplication] endBackgroundTask:self.currentBackgroundTaskIdentifier];
            self.currentBackgroundTaskIdentifier = UIBackgroundTaskInvalid;
            self.undertakingResignPipeline = NO;

            for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
                [observer applicationSigningCompleteWithError:nil];
            }
        }
    };

    if (![self _copyApplicationBundleForApplication:application extractedArchiveURL:&extractedArchiveURL applicationBundleURL:&applicationBundleURL error:&error]) {
        finishCurrentApplicationWithError(error);
        return;
    }

    // Update progress to 30% for this application.
    for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
        [observer applicationSigningUpdateProgress:30 forBundleIdentifier:originalBundleIdentifier];
    }

    //////////////////////////////////////////////////////////////////////////////////////
    // 2. Use libProvision to sign the .app
    //////////////////////////////////////////////////////////////////////////////////////

    [EEBackend signBundleAtPath:[applicationBundleURL path] identity:username gsToken:password priorChosenTeamID:teamID withCompletionHandler:^(NSError *error) {
        if (error) {
            [[NSFileManager defaultManager] removeItemAtURL:extractedArchiveURL error:nil];
            finishCurrentApplicationWithError(error);
            return;
        }

        NSDictionary *signedInfo = [NSDictionary dictionaryWithContentsOfURL:
                                    [applicationBundleURL URLByAppendingPathComponent:@"Info.plist"]];
        NSString *signedBundleIdentifier = [signedInfo[@"CFBundleIdentifier"] isKindOfClass:[NSString class]]
                                           ? signedInfo[@"CFBundleIdentifier"] : nil;
        if (signedBundleIdentifier.length == 0) {
            [[NSFileManager defaultManager] removeItemAtURL:extractedArchiveURL error:nil];
            NSError *identifierError = [self _errorFromString:
                                        @"Signing completed, but the signed app has no valid CFBundleIdentifier. Installation was stopped."
                                                          errorCode:RPVErrorFailedToInstallSignedIPA];
            finishCurrentApplicationWithError(identifierError);
            return;
        }

        // Update progress to 50% for this application.
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningUpdateProgress:50 forBundleIdentifier:originalBundleIdentifier];
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 3. Build IPA
        //////////////////////////////////////////////////////////////////////////////////////

        NSString *outputIpaPath = [[EEBackend applicationTemporaryDirectory] stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"reprovision-signed-%@.ipa", [[NSUUID UUID] UUIDString]]];

        NSError *err = nil;
        if (![EEBackend repackIpaAtPath:[extractedArchiveURL path] toPath:outputIpaPath error:&err]) {
            [[NSFileManager defaultManager] removeItemAtURL:extractedArchiveURL error:nil];
            finishCurrentApplicationWithError(err);
            return;
        }

        // Remove extracted files once the IPA has been built.
        [[NSFileManager defaultManager] removeItemAtURL:extractedArchiveURL error:nil];

        // Update progress to 60% for this application.
        for (id<RPVApplicationSigningProtocol> observer in [self.observers reverseObjectEnumerator]) {
            [observer applicationSigningUpdateProgress:60 forBundleIdentifier:originalBundleIdentifier];
        }

        //////////////////////////////////////////////////////////////////////////////////////
        // 4. Install IPA
        //////////////////////////////////////////////////////////////////////////////////////

        // Serialize installs so completion reflects the coordinator's final result.
        [self _installIpaAtPath:outputIpaPath
      originalBundleIdentifier:originalBundleIdentifier
        signedBundleIdentifier:signedBundleIdentifier
     replaceOriginalAfterSuccess:replacesInstalledApplication
                       completion:^(NSError *installationError) {
            if (installationError) {
                finishCurrentApplicationWithError(installationError);
            } else {
                finishCurrentApplicationSuccessfully();
            }
        }];
    }];
}

////////////////////////////////////////////////////////////////////////////////
// Application handling callbacks
////////////////////////////////////////////////////////////////////////////////

- (BOOL)removeApplicationWithBundleIdentifier:(NSString *)bundleIdentifier {
    BOOL ret = NO;
    if (bundleIdentifier) {
        ret = [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:bundleIdentifier withOptions:nil];
    }
    return ret;
}

@end
