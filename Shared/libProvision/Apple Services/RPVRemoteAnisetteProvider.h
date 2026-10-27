#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Preference keys for the user-selected anisette server.
extern NSString *const RPVAnisetteServerPreferenceKey;
extern NSString *const RPVAnisetteCustomServerPreferenceKey;
// RPVAnisetteServerPreferenceKey value that selects the custom server.
extern NSString *const RPVAnisetteCustomServerValue;
// RPVAnisetteServerPreferenceKey value that uses the device's own AuthKit
// anisette instead of a server (experimental on iOS 17+).
extern NSString *const RPVAnisetteAuthKitValue;
extern NSString *const RPVAnisetteDefaultServer;

/**
 Provides a persistent macOS ADI identity through the SideStore anisette v3
 protocol. The provider receives only ADI provisioning material and a random
 local UUID; Apple ID credentials and service tokens are never sent to it.
 */
@interface RPVRemoteAnisetteProvider : NSObject

/**
 Prevents automatic ADI reprovisioning while an Apple authentication session
 or GS token is using the current machine identity. A fresh manual sign-in may
 unpin the identity before GrandSlam begins.
 */
@property (nonatomic, assign, getter=isIdentityPinned) BOOL identityPinned;

/**
 User-Agent the anisette server pairs with its client info. GrandSlam rejects
 logins (-80045) when these do not match the identity the server emulates.
 */
@property (nonatomic, copy, readonly, nullable) NSString *userAgent;

/**
 Servers offered in the UI, in display order. Each entry has "value" (the host,
 or RPVAnisetteCustomServerValue) and "title". Shared by Settings and sign-in.
 */
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)serverOptions;

/**
 Name of the selected server for display, e.g. "Jkcoxson (Mac)" or the custom host.
 */
+ (NSString *)currentServerTitle;

/**
 Stores a server selection. Pass RPVAnisetteCustomServerValue together with a
 host to select a custom server. Returns NO if the custom host is invalid.
 */
+ (BOOL)selectServerValue:(NSString *)value customHost:(nullable NSString *)customHost;

/**
 The anisette server selected in settings, as an https URL without a trailing
 slash. Falls back to RPVAnisetteDefaultServer when the selection is invalid.
 */
+ (NSString *)currentServerURL;

/**
 YES when the user chose the device's own AuthKit anisette instead of a server.
 */
+ (BOOL)usesDeviceAnisette;

/**
 Discards the ADI identity stored for the current server, so the next sign-in
 provisions a new one. Existing Apple ID sessions stop working afterwards.
 */
+ (void)resetStoredStateForCurrentServer;

- (void)fetchAnisetteDataWithCompletion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable headers,
                                                   NSError * _Nullable error))completion;

/**
 Regenerates headers for the current identity after GrandSlam asks for an
 anisette resync (hsc 434), passing back the X-Apple-I-MD-DATA it returned.
 */
- (void)resyncAnisetteDataWithSIM:(NSString *)SIM
                       completion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable headers,
                                            NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
