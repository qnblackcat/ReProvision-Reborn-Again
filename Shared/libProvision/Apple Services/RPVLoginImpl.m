//
//  RPVLoginImpl.cpp
//  iOS
//
//  Created by Kabir Oberai on 11/11/19.
//  Adapted by Matt Clarke on 24/11/19.
//

#import "RPVLoginImpl.h"

#import <corecrypto/ccsrp.h>
#import <corecrypto/ccdrbg.h>
#import <corecrypto/ccsrp_gp.h>
#import <corecrypto/ccdigest.h>
#import <corecrypto/ccsha2.h>
#import <corecrypto/ccpbkdf2.h>
#import <corecrypto/cchmac.h>
#import <corecrypto/ccaes.h>
#import <corecrypto/ccpad.h>
#import <corecrypto/ccrng_system.h>

#import <dlfcn.h>
#include <errno.h>
#include <stdlib.h>

// Authentication payloads contain credentials and tokens; log metadata only.
#define DEBUG 0

// Opt-in diagnostics record response structure without sensitive values.
static NSString * const RPV2FADiagnosticsEnabledKey = @"RPV2FADiagnosticsEnabled";
static NSString * const RPV2FADiagnosticsLogPath = @"/var/mobile/Documents/ReProvision-2FA-Debug.log";
static const unsigned long long RPV2FADiagnosticsMaximumBytes = 512 * 1024;

// Modern GrandSlam transport identity; based on AltSign PR #47.
static NSString * const RPVGrandSlamUserAgent = @"AuthKit/1 (Macintosh; OS X 26.5.2) (com.apple.dt.Xcode/26.0)";
static const NSUInteger RPVGrandSlamMaximumAttempts = 3;
static const NSTimeInterval RPVGrandSlamRequestBudget = 20.0;

// GrandSlam accepts the AuthKit daemon token in client-info. Keep the provider's
// hardware, OS, and attestation values unchanged. See AltStore #1790.
static NSString *RPVCompatibleClientInfo(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    static NSRegularExpression *xcodeClient;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        xcodeClient = [NSRegularExpression regularExpressionWithPattern:@"(?<=\\()com\\.apple\\.dt\\.Xcode/[^\\s()<>]+(?=\\))"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [xcodeClient stringByReplacingMatchesInString:value options:0
        range:NSMakeRange(0, [value length]) withTemplate:@"com.apple.akd/1.0"];
}

// Returns the base64 X-Apple-I-MD-DATA GrandSlam sends when it wants an
// anisette resync (Status.hsc == 434), or nil. Based on isideload PR #26.
static NSString *RPVAnisetteResyncSIM(NSDictionary *response) {
    NSDictionary *status = [response isKindOfClass:NSDictionary.class] ? response[@"Status"] : nil;
    if (![status isKindOfClass:NSDictionary.class]) return nil;
    id hsc = status[@"hsc"];
    if (![hsc respondsToSelector:@selector(integerValue)] || [hsc integerValue] != 434) return nil;
    id SIM = status[@"X-Apple-I-MD-DATA"];
    if ([SIM isKindOfClass:NSData.class]) return [SIM length] ? [SIM base64EncodedStringWithOptions:0] : nil;
    if ([SIM isKindOfClass:NSString.class]) return [SIM length] ? SIM : nil;
    return nil;
}

// Client info used with the device's own AuthKit anisette.
static NSString * const RPVDefaultClientInfo = @"<MacBookPro11,5> <Mac OS X;10.14.6;18G103> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";

static NSString *RPVDiagnosticClientKind(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return @"missing";
    if ([value rangeOfString:@"(com.apple.dt.Xcode/" options:NSCaseInsensitiveSearch].location != NSNotFound) return @"xcode";
    if ([value rangeOfString:@"(com.apple.akd/" options:NSCaseInsensitiveSearch].location != NSNotFound) return @"akd";
    return @"other";
}

static BOOL RPV2FADiagnosticsEnabled(void) {
    return [[NSBundle.mainBundle objectForInfoDictionaryKey:RPV2FADiagnosticsEnabledKey] boolValue];
}

// Retains the native compatibility behavior used by current release builds.
static BOOL RPVNativeAuthCompatibilityEnabled(void) {
    return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"RPVNativeAuthCompatibilityTestEnabled"] boolValue];
}

static NSNumber *RPVRoutingInfoNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return nil;
    if ([value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound) return nil;
    const char *text = [value UTF8String];
    char *end = NULL;
    errno = 0;
    long long routingInfo = strtoll(text, &end, 10);
    if (errno == ERANGE || end == text || *end != '\0' || routingInfo < 0) return nil;
    return @(routingInfo);
}

static NSArray<NSString *> *RPV2FASafeDictionaryKeys(NSDictionary *dictionary) {
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    for (id key in dictionary.allKeys) {
        if ([key isKindOfClass:[NSString class]]) {
            [keys addObject:key];
        }
    }
    [keys sortUsingSelector:@selector(compare:)];
    return keys;
}

static NSString *RPV2FASafeEndpoint(NSURL *URL) {
    if (!URL) {
        return @"missing";
    }
    NSString *host = URL.host.length > 0 ? URL.host : @"unknown-host";
    NSString *path = URL.path.length > 0 ? URL.path : @"/";
    return [NSString stringWithFormat:@"%@%@", host, path];
}

static NSString *RPV2FAModeName(NSInteger mode) {
    if (mode == RPVInternalLogin2FARequiredTrustedDeviceError) {
        return @"trusted-device";
    }
    if (mode == RPVInternalLogin2FARequiredSecondaryAuthError) {
        return @"trusted-phone";
    }
    return @"unsupported";
}

static NSDictionary *RPV2FASafeResponseSummary(NSData *data,
                                                NSURLResponse *response,
                                                NSError *error) {
    NSMutableDictionary *summary = [@{ @"data_bytes": @(data.length) } mutableCopy];
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        summary[@"http_status"] = @([(NSHTTPURLResponse *)response statusCode]);
    } else {
        summary[@"http_response_present"] = @(response != nil);
    }
    if (response.MIMEType.length > 0) {
        summary[@"mime_type"] = response.MIMEType;
    }
    if (error) {
        summary[@"transport_error_domain"] = error.domain ?: @"unknown";
        summary[@"transport_error_code"] = @(error.code);
    }
    return summary;
}

// Diagnostics use fixed field names and type categories, never raw values.
static NSString *RPVDiagnosticType(id value) {
    if (!value || value == NSNull.null) return @"missing";
    if ([value isKindOfClass:NSString.class]) return [value length] ? @"string" : @"empty-string";
    if ([value isKindOfClass:NSNumber.class]) return @"number";
    if ([value isKindOfClass:NSData.class]) return [value length] ? @"data" : @"empty-data";
    if ([value isKindOfClass:NSDictionary.class]) return @"dictionary";
    if ([value isKindOfClass:NSArray.class]) return @"array";
    return @"other";
}

static NSString *RPVDiagnosticAuthMode(id value) {
    if (!value || value == NSNull.null) return @"missing";
    if ([value isEqual:@"trustedDeviceSecondaryAuth"]) return @"trusted-device";
    if ([value isEqual:@"secondaryAuth"]) return @"trusted-phone";
    return @"other";
}

static NSDictionary *RPVDiagnosticFieldTypes(NSDictionary *dictionary, NSArray<NSString *> *keys) {
    NSMutableDictionary *types = [NSMutableDictionary dictionary];
    for (NSString *key in keys) types[key] = RPVDiagnosticType(dictionary[key]);
    return types;
}

static NSDictionary *RPVGrandSlamRequestDiagnostics(NSDictionary *params, NSDictionary *headers,
                                                   NSDictionary *context) {
    NSDictionary *cpd = [params[@"cpd"] isKindOfClass:NSDictionary.class] ? params[@"cpd"] : @{};
    NSString *operation = [@[@"init", @"complete", @"apptokens"] containsObject:params[@"o"]]
        ? params[@"o"] : @"unknown";
    NSString *clientInfo = [headers[@"X-MMe-Client-Info"] isKindOfClass:NSString.class] ? headers[@"X-MMe-Client-Info"] : @"";
    NSMutableDictionary *summary = [@{
        @"diagnostic_schema": @2,
        @"operation": operation,
        @"request_field_types": RPVDiagnosticFieldTypes(params, @[@"u", @"A2k", @"ps", @"M1", @"c", @"t", @"checksum", @"app", @"cpd"]),
        @"client_field_types": RPVDiagnosticFieldTypes(cpd, @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-LU", @"X-Apple-I-MD-RINFO", @"X-Mme-Device-Id", @"X-Apple-I-Client-Time", @"X-Apple-Locale", @"X-Apple-I-TimeZone", @"X-MMe-Client-Info", @"X-Apple-I-SRL-NO", @"loc"]),
        @"client_description_present": @(clientInfo.length > 0),
        @"client_description_is_mac": @([clientInfo hasPrefix:@"<Mac"]),
        @"body_client_description_present": @(cpd[@"X-MMe-Client-Info"] != nil),
        @"body_header_client_description_match": @([cpd[@"X-MMe-Client-Info"] isEqual:clientInfo]),
        @"client_info_header_client": RPVDiagnosticClientKind(clientInfo),
        @"client_info_body_client": RPVDiagnosticClientKind(cpd[@"X-MMe-Client-Info"]),
        @"user_agent_client": RPVDiagnosticClientKind(headers[@"User-Agent"]),
        @"requested_xcode_token": @([params[@"app"] isEqual:@[@"com.apple.gs.xcode.auth"]])
    } mutableCopy];
    if (context) {
        summary[@"trace_id"] = context[@"trace_id"];
        summary[@"identity_source"] = context[@"identity_source"];
        summary[@"client_description_matches_login_start"] = @([clientInfo isEqual:context[@"initial_client_info"]]);
    }
    id deviceID = cpd[@"X-Mme-Device-Id"];
    NSString *deviceIDFormat = @"missing-or-invalid";
    if ([deviceID isKindOfClass:NSString.class] && [deviceID length] > 0) {
        if ([[NSUUID alloc] initWithUUIDString:deviceID]) deviceIDFormat = @"uuid";
        else if ([deviceID length] == 40 && [deviceID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location == NSNotFound) deviceIDFormat = @"hex40";
        else deviceIDFormat = @"other";
    }
    summary[@"device_id_format"] = deviceIDFormat;
    NSString *clientTime = [cpd[@"X-Apple-I-Client-Time"] isKindOfClass:NSString.class] ? cpd[@"X-Apple-I-Client-Time"] : nil;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSDate *date = clientTime ? [formatter dateFromString:clientTime] : nil;
    summary[@"client_time_parseable"] = @(date != nil);
    if (date) summary[@"client_clock_skew_seconds"] = @((long long)MIN(86400.0, fabs(date.timeIntervalSinceNow)));
    summary[@"checksum_bytes"] = [params[@"checksum"] isKindOfClass:NSData.class] ? @([params[@"checksum"] length]) : @0;
    return summary;
}

static void RPV2FADiagnosticLog(NSString *event, NSDictionary *fields) {
    if (!RPV2FADiagnosticsEnabled() || event.length == 0) {
        return;
    }

    NSMutableDictionary *record = [@{
        @"event": event,
        @"time_unix_ms": @((long long)(NSDate.date.timeIntervalSince1970 * 1000.0))
    } mutableCopy];
    if ([fields isKindOfClass:[NSDictionary class]]) {
        [record addEntriesFromDictionary:fields];
    }

    NSError *serializationError = nil;
    NSData *JSONData = [NSJSONSerialization dataWithJSONObject:record
                                                       options:NSJSONWritingSortedKeys
                                                         error:&serializationError];
    if (!JSONData || serializationError) {
        return;
    }

    NSMutableData *line = [JSONData mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];

    @synchronized (NSBundle.mainBundle) {
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSString *directory = RPV2FADiagnosticsLogPath.stringByDeletingLastPathComponent;
        [fileManager createDirectoryAtPath:directory
               withIntermediateDirectories:YES
                                attributes:nil
                                     error:nil];

        NSDictionary *attributes = [fileManager attributesOfItemAtPath:RPV2FADiagnosticsLogPath error:nil];
        if ([attributes fileSize] > RPV2FADiagnosticsMaximumBytes) {
            [fileManager removeItemAtPath:RPV2FADiagnosticsLogPath error:nil];
        }

        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:RPV2FADiagnosticsLogPath];
        if (fileHandle) {
            @try {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:line];
                [fileHandle closeFile];
            } @catch (__unused NSException *exception) {
                [fileHandle closeFile];
            }
        } else {
            [line writeToFile:RPV2FADiagnosticsLogPath atomically:YES];
        }
    }
}

struct ccrng_state *ccDRBGGetRngState(void);

@interface AKAppleIDSession : NSObject
- (AKAppleIDSession *)initWithIdentifier:(NSString *)identifier;
- (NSDictionary *)appleIDHeadersForRequest:(NSURLRequest *)request;
@end

@interface AKDevice : NSObject
+ (AKDevice *)currentDevice;
- (NSString *)uniqueDeviceIdentifier;
- (NSString *)MLBSerialNumber;
- (NSString *)ROMAddress;
- (NSString *)serialNumber;
@end

static void writeToLogFile(const char *string) {
#if DEBUG
    NSString *txtFileName = @"/var/mobile/Documents/ReProvisionDebug.txt";
    NSString *final = [NSString stringWithFormat:@"(%@) %s\n", [NSDate date], string];
     
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:txtFileName];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[final dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [final writeToFile:txtFileName
                atomically:NO
                  encoding:NSStringEncodingConversionAllowLossy
                     error:nil];
    }
#endif
}

OS_FORMAT_PRINTF(1, 2)
static void log_error(const char *format, ...) {
    va_list args;
    va_start(args, format);
    char *str = NULL;
    vasprintf(&str, format, args);
    va_end(args);

    NSLog(@"[ERROR] %s", str);
    writeToLogFile(str);

    free(str);
}

OS_FORMAT_PRINTF(1, 2)
static void log_debug(const char *format, ...) {
#if DEBUG
    va_list args;
    va_start(args, format);
    char *str = NULL;
    vasprintf(&str, format, args);
    va_end(args);

    NSLog(@"[DEBUG] %s", str);
    writeToLogFile(str);

    free(str);
#endif
}

static const char hexchars[] = "0123456789abcdef";

// AppleIDAuthSupport`AppleIDAuthSupportPBKDF2SRP
static NSData *PBKDF2SRP(const struct ccdigest_info *di_info, BOOL notS2K, NSString *password, NSData *salt, NSNumber *iterations) {
    const struct ccdigest_info *password_di_info = ccsha256_di();
    char digest_raw[password_di_info->output_size];
    const char *passwordUTF8 = password.UTF8String;
    ccdigest(password_di_info, strlen(passwordUTF8), passwordUTF8, digest_raw);

    size_t final_digest_len = password_di_info->output_size * (notS2K ? 2 : 1);
    char digest[final_digest_len];

    if (notS2K) {
        // s2k_fo passes a hex string version of the bytes instead
        for (size_t i = 0; i < password_di_info->output_size; i++) {
            char byte = digest_raw[i];
            digest[i * 2 + 0] = hexchars[(byte >> 4) & 0x0F];
            digest[i * 2 + 1] = hexchars[(byte >> 0) & 0x0F];
        }
    } else {
        memcpy(digest, digest_raw, final_digest_len);
    }

    NSMutableData *data = [NSMutableData dataWithLength:di_info->output_size];
    int result = ccpbkdf2_hmac(di_info,
                               final_digest_len, digest,
                               salt.length, salt.bytes,
                               iterations.integerValue,
                               di_info->output_size, data.mutableBytes);
    if (result != 0) return nil;
    return data;
}

// AppleIDAuthSupport`addStringToNegProt
static void addStringToNegProt(const struct ccdigest_info *di_info, struct ccdigest_ctx *di_ctx, const char *str) {
    ccdigest_update(di_info, di_ctx, strlen(str), str);
}

// AppleIDAuthSupport`addDataToNegProt
static void addDataToNegProt(const struct ccdigest_info *di_info, struct ccdigest_ctx *di_ctx, NSData *data) {
    uint32_t data_len = (uint32_t)data.length; // 4 bytes for length
    ccdigest_update(di_info, di_ctx, sizeof(data_len), &data_len);
    ccdigest_update(di_info, di_ctx, data_len, data.bytes);
}

// AppleIDAuthSupport`SRPCreateSessionKey
static NSData *createSessionKey(ccsrp_ctx_t srp_ctx, const char *key_name) {
    size_t key_len;
    const void *session_key = ccsrp_get_session_key(srp_ctx, &key_len);
    const struct ccdigest_info *di_info = ccsha256_di();
    size_t hmac_len = di_info->output_size;
    unsigned char hmac_bytes[hmac_len];
    cchmac(di_info, key_len, session_key, strlen(key_name), key_name, hmac_bytes);
    return [NSData dataWithBytes:hmac_bytes length:hmac_len];
}

// AppleIDAuthSupport`CreateDecryptedData
static NSData *decryptCBC(ccsrp_ctx_t srp_ctx, NSData *spd) {
    NSData *extraDataKey = createSessionKey(srp_ctx, "extra data key:");
    NSData *extraDataIV = createSessionKey(srp_ctx, "extra data iv:");

    NSMutableData *decrypted = [NSMutableData dataWithLength:spd.length];

    const struct ccmode_cbc *decrypt_mode = ccaes_cbc_decrypt_mode();
    cccbc_iv iv[decrypt_mode->block_size];
    if (extraDataIV.bytes) {
        memcpy(iv, extraDataIV.bytes, decrypt_mode->block_size);
    } else {
        bzero(iv, decrypt_mode->block_size);
    }

    cccbc_ctx ctx_buf[decrypt_mode->size];
    decrypt_mode->init(decrypt_mode, ctx_buf, extraDataKey.length, extraDataKey.bytes);

    size_t len = ccpad_pkcs7_decrypt(decrypt_mode, ctx_buf, iv, spd.length, spd.bytes, decrypted.mutableBytes);
    if (len > spd.length) {
        log_error("decrypted len > spd len");
        return nil;
    }

    return decrypted;
}

// AppleIDAuthSupport`_AppleIDAuthSupportCreateDecryptedData
static NSData *decryptGCM(NSData *sk, NSData *encrypted) {
    const struct ccmode_gcm *decrypt_mode = ccaes_gcm_decrypt_mode();
    ccgcm_ctx gcm_ctx[decrypt_mode->size];
    decrypt_mode->init(decrypt_mode, gcm_ctx, sk.length, sk.bytes);
    if (encrypted.length < 35) {
        log_error("Encrypted token too short!");
        return nil;
    }
    if (cc_cmp_safe(3, encrypted.bytes, "XYZ")) {
        log_error("Encrypted token wrong version!");
        return nil;
    }
    decrypt_mode->set_iv(gcm_ctx, 16, (unsigned char*)encrypted.bytes + 3);
    decrypt_mode->gmac(gcm_ctx, 3, encrypted.bytes);

    size_t decrypted_len = encrypted.length - 35;
    NSMutableData *decrypted = [NSMutableData dataWithLength:decrypted_len];
    decrypt_mode->gcm(gcm_ctx, decrypted_len, (unsigned char*)encrypted.bytes + 16 + 3, decrypted.mutableBytes);

    char tag[16];
    decrypt_mode->finalize(gcm_ctx, 16, tag);
    if (cc_cmp_safe(16, (unsigned char*)encrypted.bytes + decrypted_len + 19, tag)) {
        log_error("Invalid tag version");
        return nil;
    }

    return decrypted;
}

// AppleIDAuthSupport`cfHMAC
static void update_hmac(const struct ccdigest_info *di_info, struct cchmac_ctx *hmac_ctx, id value) {
    if ([value isKindOfClass:NSArray.class]) {
        NSArray<NSString *> *apps = value;
        for (NSString *app in apps) {
            update_hmac(di_info, hmac_ctx, app);
        }
    } else if ([value isKindOfClass:NSString.class]) {
        NSString *app = value;
        const char *appUTF8 = app.UTF8String;
        cchmac_update(di_info, hmac_ctx, strlen(appUTF8), appUTF8);
    } else if ([value isKindOfClass:NSData.class]) {
        NSData *appData = value;
        cchmac_update(di_info, hmac_ctx, appData.length, appData.bytes);
    } else {
        // Malformed values are reported by type only.
        log_error("Invalid hmac value type");
    }
}

// AppleIDAuthSupport`CreateAppTokensChecksum
static NSData *createAppTokensChecksum(NSData *sk, NSString *adsid, NSArray<NSString *> *apps) {
    const struct ccdigest_info *di_info = ccsha256_di();
    size_t hmac_size = cchmac_di_size(di_info);
    struct cchmac_ctx hmac_ctx[hmac_size];
    cchmac_init(di_info, hmac_ctx, sk.length, sk.bytes);

    const char *key = "apptokens";
    cchmac_update(di_info, hmac_ctx, strlen(key), key);

    const char *adsidUTF8 = adsid.UTF8String;
    cchmac_update(di_info, hmac_ctx, strlen(adsidUTF8), adsidUTF8);

    update_hmac(di_info, hmac_ctx, apps);

    NSMutableData *data = [NSMutableData dataWithLength:di_info->output_size];
    cchmac_final(di_info, hmac_ctx, (unsigned char*)data.mutableBytes);

    return data;
}

static NSInteger RPVDecimalDigitValue(unichar character) {
    // Convert localized keypad and AutoFill digits to the ASCII form Apple expects.
    static const unichar digitBlockStarts[] = {
        0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66,
        0x0AE6, 0x0B66, 0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0DE6,
        0x0E50, 0x0ED0, 0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810,
        0x1946, 0x19D0, 0x1A80, 0x1A90, 0x1B50, 0x1BB0, 0x1C40,
        0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, 0xA9F0, 0xAA50,
        0xABF0, 0xFF10
    };

    for (NSUInteger index = 0;
         index < sizeof(digitBlockStarts) / sizeof(digitBlockStarts[0]);
         index++) {
        unichar start = digitBlockStarts[index];
        if (character >= start && character <= start + 9) {
            return character - start;
        }
    }
    return NSNotFound;
}

static NSString *RPVNormalizedVerificationCode(NSString *code) {
    NSMutableString *result = [NSMutableString stringWithCapacity:6];
    for (NSUInteger index = 0; index < code.length; index++) {
        NSInteger digit = RPVDecimalDigitValue([code characterAtIndex:index]);
        if (digit != NSNotFound) {
            [result appendFormat:@"%ld", (long)digit];
        }
    }
    return result;
}

@interface RPVLoginImpl ()

@property (nonatomic, strong) NSDictionary *lookupURLs;
@property (nonatomic, copy) NSString *twoFactorPhoneNumberID;
@property (nonatomic, copy) NSString *twoFactorPhoneDeliveryMode;

#if TARGET_OS_IOS
@property (nonatomic, readwrite) struct ccrng_state *rngState;
#endif

@end

@implementation RPVLoginImpl

@synthesize clientInfoOverride = _clientInfoOverride;
@synthesize anisetteDataOverride = _anisetteDataOverride;

- (void)setClientInfoOverride:(NSString *)clientInfo {
    _clientInfoOverride = [RPVCompatibleClientInfo(clientInfo) copy];
    RPV2FADiagnosticLog(@"client_info.normalized", @{
        @"source": @"client-description",
        @"input_client": RPVDiagnosticClientKind(clientInfo),
        @"output_client": RPVDiagnosticClientKind(_clientInfoOverride),
        @"changed": @(![_clientInfoOverride isEqual:clientInfo] && clientInfo != nil)
    });
}

- (void)setAnisetteDataOverride:(NSDictionary *)headers {
    if (![headers isKindOfClass:NSDictionary.class]) {
        _anisetteDataOverride = nil;
        return;
    }
    NSMutableDictionary *compatibleHeaders = [headers mutableCopy];
    NSString *original = headers[@"X-MMe-Client-Info"];
    NSString *compatible = RPVCompatibleClientInfo(original);
    if (compatible) compatibleHeaders[@"X-MMe-Client-Info"] = compatible;
    _anisetteDataOverride = [compatibleHeaders copy];
    RPV2FADiagnosticLog(@"client_info.normalized", @{
        @"source": @"anisette-override",
        @"input_client": RPVDiagnosticClientKind(original),
        @"output_client": RPVDiagnosticClientKind(compatible),
        @"changed": @(compatible != nil && ![compatible isEqual:original])
    });
}

- (void)applyRemoteAnisetteHeaders:(NSDictionary *)headers userAgent:(NSString *)userAgent {
    // GrandSlam answers -80045 when client info or User-Agent differ from the
    // identity the anisette server emulates, so send both unchanged.
    // Based on isideload PR #26 (iloader 2.3.7).
    _anisetteDataOverride = [headers isKindOfClass:NSDictionary.class] ? [headers copy] : nil;
    NSString *clientInfo = _anisetteDataOverride[@"X-MMe-Client-Info"];
    if ([clientInfo isKindOfClass:NSString.class] && clientInfo.length > 0) {
        _clientInfoOverride = [clientInfo copy];
    }
    if (userAgent.length > 0) {
        self.userAgentOverride = userAgent;
    }
    RPV2FADiagnosticLog(@"client_info.remote", @{
        @"client": RPVDiagnosticClientKind(_clientInfoOverride),
        @"server_user_agent": @(userAgent.length > 0)
    });
}

- (void)clearRemoteAnisetteOverrides {
    if (_anisetteDataOverride.count == 0 && self.userAgentOverride.length == 0)
        return;
    _anisetteDataOverride = nil;
    self.userAgentOverride = nil;
    self.clientInfoOverride = RPVDefaultClientInfo;
    RPV2FADiagnosticLog(@"client_info.device", @{@"client": RPVDiagnosticClientKind(_clientInfoOverride)});
}

- (instancetype)init {
    self = [super init];

    if (self) {
        self.clientInfoOverride = RPVDefaultClientInfo;
        
#if TARGET_OS_IOS
        // Create rng pointer
        
        NSOperatingSystemVersion version;
        version.majorVersion = 10;
        version.minorVersion = 0;
        version.patchVersion = 0;
        
        if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:version]) {
            self.rngState = ccrng(NULL);
        } else {
            self.rngState = (struct ccrng_state*)malloc(sizeof(struct ccrng_system_state));
            ccrng_system_init((struct ccrng_system_state*)self.rngState);
        }
#endif
        
    }
    
    return self;
}

- (void)dealloc {
#if TARGET_OS_IOS

    // Free rng pointer if needed
    NSOperatingSystemVersion version;
    version.majorVersion = 10;
    version.minorVersion = 0;
    version.patchVersion = 0;
    
    if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:version]) {
        ccrng_system_done((struct ccrng_system_state*)self.rngState);
    }
    
#endif
}

-(NSError*)createError:(NSString *)string :(int)code {
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

- (void)_ensureAuthKitAvailable {
    dlopen("/System/Library/PrivateFrameworks/AuthKit.framework/AuthKit", RTLD_NOW);
}

- (NSMutableURLRequest *)_nativeAnisetteContextRequest {
    // AuthKit uses this request only as context when generating headers.
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        @"https://developerservices2.apple.com/services/QH65B2/viewDeveloper.action?clientId=XABBG36SBA"]];
    request.HTTPMethod = @"POST";
    return request;
}

- (NSDictionary *)_anisetteData {
    if (self.anisetteDataOverride.count > 0) {
        return self.anisetteDataOverride;
    }
#if TARGET_OS_SIMULATOR
    NSURL *bridgeURL = [NSURL URLWithString:@"http://127.0.0.1:6970/headers"];
    NSMutableURLRequest *bridgeRequest = [NSMutableURLRequest requestWithURL:bridgeURL
                                                                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                            timeoutInterval:15.0];
    dispatch_semaphore_t bridgeSemaphore = dispatch_semaphore_create(0);
    __block NSDictionary *bridgeHeaders = nil;
    __block NSError *bridgeError = nil;
    NSURLSessionDataTask *bridgeTask = [[NSURLSession sharedSession]
        dataTaskWithRequest:bridgeRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data && !error && [(NSHTTPURLResponse *)response statusCode] == 200) {
            id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&bridgeError];
            if ([object isKindOfClass:[NSDictionary class]]) {
                bridgeHeaders = object;
            }
        } else {
            bridgeError = error ?: [NSError errorWithDomain:NSURLErrorDomain
                                                       code:[(NSHTTPURLResponse *)response statusCode]
                                                   userInfo:nil];
        }
        dispatch_semaphore_signal(bridgeSemaphore);
    }];
    [bridgeTask resume];
    dispatch_semaphore_wait(bridgeSemaphore,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16.0 * NSEC_PER_SEC)));
    if (!bridgeHeaders) {
        log_error("Simulator anisette bridge unavailable: %s",
                  bridgeError.localizedDescription.UTF8String ?: "request timed out");
        return @{};
    }
    return bridgeHeaders;
#else
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    NSString *dateString = [formatter stringFromDate:[NSDate date]];

    [self _ensureAuthKitAvailable];

    Class AKAppleIDSession = NSClassFromString(@"AKAppleIDSession");
    NSURLRequest *contextRequest = RPVNativeAuthCompatibilityEnabled() ? [self _nativeAnisetteContextRequest] : nil;
    NSDictionary *headers = [[[AKAppleIDSession alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"] appleIDHeadersForRequest:contextRequest];
    RPV2FADiagnosticLog(@"native_anisette.result", @{
        @"context_request_supplied": @(contextRequest != nil),
        @"header_field_types": RPVDiagnosticFieldTypes(headers, @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-LU", @"X-Apple-I-MD-RINFO"])
    });
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    [result setObject:dateString forKey:@"X-Apple-I-Client-Time"];
    [result setObject:NSLocale.currentLocale.localeIdentifier forKey:@"X-Apple-Locale"];
    [result setObject:NSTimeZone.localTimeZone.abbreviation forKey:@"X-Apple-I-TimeZone"];
    
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [result setObject:value forKey:key];
    }];
    
    [result setObject:self.clientInfoOverride forKey:@"X-MMe-Client-Info"];

    return result;
#endif
}

- (NSDictionary *)_deviceData {
    // Remote ADI data already includes its matching device identity.
    if (self.anisetteDataOverride.count > 0) {
        return @{};
    }
#if TARGET_OS_SIMULATOR
    // The simulator bridge supplies the stable Mac-format device identifier.
    return @{};
#else
    // Note: X-Apple-I-PRK is also sent, however it's a password reset key which (I think) may not always
    // be present even in genuine requests. It requires another account on device. So let's not include
    // it for now.
    //
    // In fact, the only X-whatever key required here is the device X-Mme-Device-Id
    // (which I believe must match that of a provisioned device)

    [self _ensureAuthKitAvailable];
    
    AKDevice *device = [NSClassFromString(@"AKDevice") currentDevice];
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    
    if (device.uniqueDeviceIdentifier)
        [result setObject:device.uniqueDeviceIdentifier forKey:@"X-Mme-Device-Id"];
    
    if ([device respondsToSelector:@selector(MLBSerialNumber)] && device.MLBSerialNumber)
        [result setObject:device.MLBSerialNumber forKey:@"X-Apple-I-MLB"];
    
    if ([device respondsToSelector:@selector(ROMAddress)] && device.ROMAddress)
        [result setObject:device.ROMAddress forKey:@"X-Apple-I-ROM"];
    
    if (device.serialNumber)
        [result setObject:device.serialNumber forKey:@"X-Apple-I-SRL-NO"];
    
    return result;
#endif
}

- (NSDictionary*)defaultRequestHeaders {
    return @{
        @"X-MMe-Client-Info": self.clientInfoOverride,
        @"Content-Type": @"text/x-xml-plist",
        @"User-Agent": self.userAgentOverride ?: RPVGrandSlamUserAgent,
        @"Accept": @"*/*"
    };
}

- (NSMutableDictionary *)_grandSlamClientData {
    NSMutableDictionary *clientData = [@{
        @"bootstrap": @YES, @"icscrec": @YES,
        @"loc": NSLocale.currentLocale.localeIdentifier,
        @"pbe": @NO, @"prkgen": @YES, @"svct": @"iCloud"
    } mutableCopy];
    [clientData addEntriesFromDictionary:[self _anisetteData]];
    [clientData addEntriesFromDictionary:[self _deviceData]];
    if (RPVNativeAuthCompatibilityEnabled()) {
        // Normalize routing info only in the plist body; header values stay strings.
        id original = clientData[@"X-Apple-I-MD-RINFO"];
        NSNumber *routingInfo = RPVRoutingInfoNumber(original);
        if (routingInfo) clientData[@"X-Apple-I-MD-RINFO"] = routingInfo;
        RPV2FADiagnosticLog(@"client_data.routing_info", @{
            @"input_type": RPVDiagnosticType(original),
            @"output_type": RPVDiagnosticType(clientData[@"X-Apple-I-MD-RINFO"]),
            @"numeric_value_available": @(routingInfo != nil)
        });
    }
    return clientData;
}

- (void)makeRequestWithParameters:(NSDictionary*)params completion:(void (^)(NSError *err, NSDictionary *response))completionHandler {
    [self _makeRequestWithParameters:params diagnosticContext:nil completion:completionHandler];
}

- (NSURLSession *)_newGrandSlamSessionWithTimeout:(NSTimeInterval)timeout {
    // Use an isolated connection pool for every attempt. Based on AltSign PR #49.
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    configuration.URLCredentialStorage = nil;
    // Share cookies, not connections.
    configuration.HTTPCookieStorage = NSHTTPCookieStorage.sharedHTTPCookieStorage;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = timeout;
    configuration.timeoutIntervalForResource = timeout;
    return [NSURLSession sessionWithConfiguration:configuration];
}

- (void)_performGrandSlamRequest:(NSURLRequest *)request
                       attempt:(NSUInteger)attempt
                      deadline:(NSTimeInterval)deadline
                   diagnostics:(NSDictionary *)diagnostics
                    completion:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
    if (remaining <= 0) {
        completion(nil, nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]);
        return;
    }
    NSMutableURLRequest *attemptRequest = [request mutableCopy];
    attemptRequest.timeoutInterval = MIN(10.0, remaining);
    NSURLSession *session = [self _newGrandSlamSessionWithTimeout:attemptRequest.timeoutInterval];
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:attemptRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
        NSInteger status = http.statusCode;
        NSMutableDictionary *event = [diagnostics mutableCopy] ?: [NSMutableDictionary dictionary];
        event[@"attempt"] = @(attempt);
        event[@"http_status"] = @(status);
        event[@"fresh_session"] = @YES;
        event[@"transport_revision"] = @2;
        event[@"modern_user_agent"] = @([[request valueForHTTPHeaderField:@"User-Agent"] isEqual:RPVGrandSlamUserAgent]);
        event[@"duration_ms"] = @((long long)((NSProcessInfo.processInfo.systemUptime - start) * 1000));
        if (error) event[@"transport_error_code"] = @(error.code);
        RPV2FADiagnosticLog(@"grandslam.transport_attempt", event);

        // Retry server failures only; credential, 2FA, 4xx, and parse errors are final.
        BOOL appleError = NO;
        if (!error && status >= 500 && status <= 599 && data.length) {
            id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
            id packed = [plist isKindOfClass:NSDictionary.class] ? plist[@"Response"] : nil;
            id result = [packed isKindOfClass:NSDictionary.class] ? packed[@"Status"] : nil;
            id code = [result isKindOfClass:NSDictionary.class] ? result[@"ec"] : nil;
            if ([code isKindOfClass:NSNumber.class]) appleError = [code longLongValue] != 0;
            else if ([code isKindOfClass:NSString.class]) {
                NSScanner *scanner = [NSScanner scannerWithString:code];
                long long value = 0;
                appleError = [scanner scanLongLong:&value] && scanner.isAtEnd && value != 0;
            }
        }
        NSTimeInterval delay = (NSTimeInterval)(1UL << MIN(attempt - 1, (NSUInteger)3));
        NSString *retryAfter = [http valueForHTTPHeaderField:@"Retry-After"];
        if (retryAfter.length) {
            NSScanner *scanner = [NSScanner scannerWithString:retryAfter];
            long long seconds = 0;
            if ([scanner scanLongLong:&seconds] && scanner.isAtEnd && seconds >= 0) {
                delay = MAX(delay, (NSTimeInterval)seconds);
            } else {
                NSDateFormatter *formatter = [NSDateFormatter new];
                formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
                formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
                formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
                NSDate *date = [formatter dateFromString:retryAfter];
                if (date) delay = MAX(delay, date.timeIntervalSinceNow);
            }
        }
        if (!error && !appleError && status >= 500 && status <= 599 &&
            attempt < RPVGrandSlamMaximumAttempts &&
            NSProcessInfo.processInfo.systemUptime + delay + 1.0 < deadline) {
            event[@"retry_delay_seconds"] = @(delay);
            RPV2FADiagnosticLog(@"grandslam.retry", event);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [self _performGrandSlamRequest:request attempt:attempt + 1 deadline:deadline diagnostics:diagnostics completion:completion];
            });
            return;
        }
        completion(data, response, error);
    }];
    [task resume];
}

- (void)_makeRequestWithParameters:(NSDictionary*)params diagnosticContext:(NSDictionary *)diagnosticContext completion:(void (^)(NSError *err, NSDictionary *response))completionHandler {
    NSString *internalEndpoint = @"https://gsa.apple.com/grandslam/GsService2";
    
    NSDictionary *defaultHeaders = [self defaultRequestHeaders];

    NSDictionary *requestBody = @{
        @"Header": @{
            @"Version": @"1.0.1"
        },
        @"Request": params
    };

    log_debug("Request Body: %s", requestBody.description.UTF8String);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:internalEndpoint]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSPropertyListSerialization dataWithPropertyList:requestBody
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:nil];
    
    [defaultHeaders enumerateKeysAndObjectsUsingBlock:^(id  _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        [request setValue:obj forHTTPHeaderField:key];
    }];

    NSString *diagnosticRequestID = RPV2FADiagnosticsEnabled() ? NSUUID.UUID.UUIDString : nil;
    NSTimeInterval diagnosticStart = NSProcessInfo.processInfo.systemUptime;
    if (diagnosticRequestID) {
        NSMutableDictionary *summary = [RPVGrandSlamRequestDiagnostics(params, defaultHeaders, diagnosticContext) mutableCopy];
        summary[@"request_id"] = diagnosticRequestID;
        summary[@"cookie_handling_enabled"] = @(request.HTTPShouldHandleCookies);
        summary[@"existing_cookie_count"] = @([[NSHTTPCookieStorage.sharedHTTPCookieStorage cookiesForURL:request.URL] count]);
        RPV2FADiagnosticLog(@"grandslam.request", summary);
    }
    
    NSString *safeOperation = [@[@"init", @"complete", @"apptokens"] containsObject:params[@"o"]] ? params[@"o"] : @"unknown";
    NSDictionary *transportDiagnostics = @{@"operation": safeOperation,
        @"request_id": diagnosticRequestID ?: @"disabled", @"trace_id": diagnosticContext[@"trace_id"] ?: @"unscoped"};
    [self _performGrandSlamRequest:request attempt:1
        deadline:NSProcessInfo.processInfo.systemUptime + RPVGrandSlamRequestBudget
        diagnostics:transportDiagnostics completion:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSString *operation = [params[@"o"] isKindOfClass:[NSString class]] ? params[@"o"] : @"unknown";
        // Record the stage and status, not request contents.
        NSMutableDictionary *summary = [RPV2FASafeResponseSummary(data, response, error) mutableCopy];
        summary[@"operation"] = [@[@"init", @"complete", @"apptokens"] containsObject:operation] ? operation : @"unknown";
        if (diagnosticRequestID) {
            summary[@"diagnostic_schema"] = @2;
            summary[@"request_id"] = diagnosticRequestID;
            if (diagnosticContext[@"trace_id"]) summary[@"trace_id"] = diagnosticContext[@"trace_id"];
            summary[@"duration_ms"] = @((long long)((NSProcessInfo.processInfo.systemUptime - diagnosticStart) * 1000));
            summary[@"response_url_matches_request"] = @([response.URL isEqual:request.URL]);
            summary[@"response_https"] = @([response.URL.scheme isEqualToString:@"https"]);
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (id)response : nil;
            summary[@"set_cookie_present"] = @([http valueForHTTPHeaderField:@"Set-Cookie"] != nil);
            summary[@"www_authenticate_present"] = @([http valueForHTTPHeaderField:@"WWW-Authenticate"] != nil);
            summary[@"via_header_present"] = @([http valueForHTTPHeaderField:@"Via"] != nil);
            NSString *server = [[http valueForHTTPHeaderField:@"Server"] lowercaseString];
            summary[@"server_family"] = !server ? @"missing" : [server containsString:@"apple"] ? @"apple"
                : [server containsString:@"nginx"] ? @"nginx" : [server containsString:@"envoy"] ? @"envoy" : @"other";
            NSString *retryAfter = [http valueForHTTPHeaderField:@"Retry-After"];
            summary[@"retry_after_present"] = @(retryAfter != nil);
            long long delay = 0;
            NSScanner *scanner = [NSScanner scannerWithString:retryAfter ?: @""];
            if ([scanner scanLongLong:&delay] && scanner.isAtEnd && delay >= 0 && delay <= 86400) summary[@"retry_after_seconds"] = @(delay);
        }
        RPV2FADiagnosticLog(@"grandslam.response", summary);
        if (error) {
            completionHandler(error, nil);
        } else if (![response isKindOfClass:[NSHTTPURLResponse class]] ||
                   [(NSHTTPURLResponse *)response statusCode] < 200 ||
                   [(NSHTTPURLResponse *)response statusCode] >= 300) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
            completionHandler([self createError:[NSString stringWithFormat:@"Apple authentication service failed during %@ (HTTP %ld). Please try again later.", summary[@"operation"], (long)status]
                                               :RPVInternalLoginError], nil);
        } else if (data.length == 0) {
            completionHandler([self createError:@"Apple returned an empty authentication response"
                                               :RPVInternalLoginError], nil);
        } else {
            NSError *parseError = nil;
            id responseObject = [NSPropertyListSerialization propertyListWithData:data
                                                                           options:0
                                                                            format:nil
                                                                             error:&parseError];
            NSDictionary *responseDictionary = [responseObject isKindOfClass:[NSDictionary class]] ? responseObject : nil;
            NSDictionary *packedResponse = [responseDictionary[@"Response"] isKindOfClass:[NSDictionary class]]
                ? responseDictionary[@"Response"]
                : nil;

            NSDictionary *status = [packedResponse[@"Status"] isKindOfClass:[NSDictionary class]] ? packedResponse[@"Status"] : nil;
            id rawCode = status[@"ec"];
            RPV2FADiagnosticLog(@"grandslam.parsed", @{
                @"operation": summary[@"operation"],
                @"request_id": diagnosticRequestID ?: @"disabled",
                @"trace_id": diagnosticContext[@"trace_id"] ?: @"unscoped",
                @"outer_auth_mode": RPVDiagnosticAuthMode(status[@"au"]),
                @"response_field_types": RPVDiagnosticFieldTypes(packedResponse, @[@"Status", @"M2", @"spd", @"et"]),
                @"parsed_response": @(packedResponse != nil),
                @"apple_code_present": @([rawCode respondsToSelector:@selector(integerValue)]),
                @"apple_code": [rawCode respondsToSelector:@selector(integerValue)] ? @([rawCode integerValue]) : @0
            });

            if (!packedResponse) {
                completionHandler(parseError ?: [self createError:@"Apple returned an unreadable authentication response"
                                                                :RPVInternalLoginError], nil);
                return;
            }
            
            log_debug("Response: %s", packedResponse.description.UTF8String);
            
            completionHandler(nil, packedResponse);
        }
        
    }];
}

- (void)initialiseLookup:(void (^)(NSError*))completion {
    if (self.lookupURLs) {
        dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            completion(nil);
        });
        return;
    }
    
    NSURL *URL = [NSURL URLWithString:@"https://gsa.apple.com/grandslam/GsService2/lookup"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    
    log_debug("Doing lookup");
    
    // Sort out headers
    NSMutableDictionary<NSString *, NSString *> *httpHeaders = [@{
        @"Content-Type": @"text/x-xml-plist",
        @"User-Agent": self.userAgentOverride ?: @"akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0",
        @"Accept": @"text/x-xml-plist",
        @"Accept-Language": @"en-us",
        @"X-Apple-App-Info": @"com.apple.gs.xcode.auth",
        @"X-Xcode-Version": @"14.2 (14C18)",
    } mutableCopy];
    
    [httpHeaders addEntriesFromDictionary:[self _anisetteData]];
    [httpHeaders addEntriesFromDictionary:[self _deviceData]];
    
    [httpHeaders enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    
    log_debug("Request Headers: %s", httpHeaders.description.UTF8String);
    
    // Do the request
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        
        log_debug("Response code: %ld", (long)[(NSHTTPURLResponse*)response statusCode]);
        RPV2FADiagnosticLog(@"lookup.response", RPV2FASafeResponseSummary(data, response, error));
        
        if (error) {
            completion(error);
        } else if (data.length == 0) {
            completion([self createError:@"Apple returned an empty authentication lookup response"
                                        :RPVInternalLoginError]);
        } else {
            // Parse the response
            NSError *parseError = nil;
            id responseObject = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:&parseError];
            NSDictionary *responseDictionary = [responseObject isKindOfClass:[NSDictionary class]] ? responseObject : nil;
            NSDictionary *lookupURLs = [responseDictionary[@"urls"] isKindOfClass:[NSDictionary class]]
                ? responseDictionary[@"urls"]
                : nil;
            
            if (lookupURLs.count > 0) {
                log_debug("Reponse: %s", responseDictionary.description.UTF8String);
                self.lookupURLs = lookupURLs;
            } else {
                completion(parseError ?: [self createError:@"Apple returned an unreadable authentication lookup response"
                                                       :RPVInternalLoginError]);
                return;
            }
            
            dispatch_async(dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                completion(nil);
            });
        }
    }];
    [task resume];
}

- (NSError *)_resyncAnisetteWithSIM:(NSString *)SIM {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSDictionary *freshHeaders = nil;
    __block NSError *resyncError = nil;
    self.anisetteResyncHandler(SIM, ^(NSDictionary *headers, NSError *error) {
        freshHeaders = headers;
        resyncError = error;
        dispatch_semaphore_signal(semaphore);
    });
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    RPV2FADiagnosticLog(@"anisette.resync", @{@"succeeded": @(freshHeaders.count > 0 && !resyncError)});

    if (freshHeaders.count == 0 || resyncError) {
        return resyncError ?: [self createError:@"Apple asked to resync anisette, but the anisette server could not resync"
                                               :RPVInternalLoginError];
    }
    [self applyRemoteAnisetteHeaders:freshHeaders userAgent:self.userAgentOverride];
    return nil;
}

#pragma mark API

- (void)loginWithUsername:(NSString*)username password:(NSString*)password completion:(RPVLoginResultBlock)completionHandler {
    NSDictionary *diagnosticContext = nil;
    if (RPV2FADiagnosticsEnabled()) {
#if TARGET_OS_SIMULATOR
        NSString *source = @"simulator-bridge";
#else
        NSString *source = self.anisetteDataOverride.count > 0 ? @"remote-override" : @"native-authkit";
#endif
        diagnosticContext = @{@"trace_id": NSUUID.UUID.UUIDString,
                              @"identity_source": source,
                              @"initial_client_info": self.clientInfoOverride ?: @""};
        RPVLoginResultBlock originalCompletion = [completionHandler copy];
        completionHandler = ^(NSError *error, NSString *userIdentity, NSString *gsToken, NSString *idmsToken) {
            RPV2FADiagnosticLog(@"login.result", @{
                @"diagnostic_schema": @2,
                @"trace_id": diagnosticContext[@"trace_id"],
                @"error_domain": error.domain ?: @"none",
                @"error_code": @(error ? error.code : 0),
                @"has_user_identity": @(userIdentity.length > 0),
                @"has_app_token": @(gsToken.length > 0),
                @"has_idms_token": @(idmsToken.length > 0)
            });
            originalCompletion(error, userIdentity, gsToken, idmsToken);
        };
    }
    RPV2FADiagnosticLog(@"login.begin", @{
        @"diagnostic_schema": @2,
        @"native_auth_compatibility_test": @(RPVNativeAuthCompatibilityEnabled()),
        @"trace_id": diagnosticContext[@"trace_id"] ?: @"disabled",
        @"identity_source": diagnosticContext[@"identity_source"] ?: @"disabled",
        @"lookup_cached": @(self.lookupURLs.count > 0),
        @"os_version": NSProcessInfo.processInfo.operatingSystemVersionString ?: @"unknown",
        @"package_version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown"
    });
    
    // Ensure lookup URLs are populated first
    [self initialiseLookup:^(NSError *error) {
        if (error) {
            completionHandler(error, nil, nil, nil);
        } else {
    
            NSMutableDictionary *clientData = [self _grandSlamClientData];

            ccsrp_const_gp_t gp = ccsrp_gp_rfc5054_2048();
            
            const struct ccdigest_info *di_info = ccsha256_di();
            struct ccdigest_ctx *di_ctx = (struct ccdigest_ctx *)malloc(ccdigest_di_size(di_info));
            ccdigest_init(di_info, di_ctx);
            
            // MARK: AppleIDAuthSupport`stateClientNeg1
            
            const struct ccdigest_info *srp_di = ccsha256_di();
            struct ccsrp_ctx *srp_ctx = (struct ccsrp_ctx *)malloc(ccsrp_sizeof_srp(di_info, gp));
            ccsrp_ctx_init(srp_ctx, srp_di, gp);
            ccsrp_client_set_noUsernameInX(srp_ctx, true);
            SRP_RNG(srp_ctx) = ccrng(NULL);

            NSArray<NSString *> *ps = @[@"s2k", @"s2k_fo"];
            for (int i = 0; i < ps.count; i++) {
                addStringToNegProt(di_info, di_ctx, ps[i].UTF8String);
                if (i != ps.count - 1) addStringToNegProt(di_info, di_ctx, ",");
            }

            size_t A_size = ccsrp_exchange_size(srp_ctx);
            char A_bytes[A_size];
            ccsrp_client_start_authentication(srp_ctx, ccDRBGGetRngState(), A_bytes);

            NSData *AData = [NSData dataWithBytes:A_bytes length:A_size];

            addStringToNegProt(di_info, di_ctx, "|");
            
            // Initial request to GSA

            NSDictionary *(^sendInitRequest)(NSDictionary *) = ^NSDictionary *(NSDictionary *cpd) {
                dispatch_semaphore_t initSemaphore = dispatch_semaphore_create(0);
                __block NSDictionary *initResponse = nil;
                [self _makeRequestWithParameters:@{
                    @"A2k": AData,
                    @"ps": ps,
                    @"cpd": cpd,
                    @"u": username,
                    @"o": @"init"
                } diagnosticContext:diagnosticContext completion:^(NSError *err, NSDictionary *response) {
                    if (response) {
                        initResponse = response;
                    } else {
                        completionHandler(err, nil, nil, nil);
                    }

                    dispatch_semaphore_signal(initSemaphore);
                }];
                dispatch_semaphore_wait(initSemaphore, DISPATCH_TIME_FOREVER);
                return initResponse;
            };
            NSDictionary *initResponse = sendInitRequest(clientData);

            // Handle response
            if (!initResponse) {
                return;
            }

            // GrandSlam may ask for fresh anisette (hsc 434); resync once and retry init.
            NSString *resyncSIM = RPVAnisetteResyncSIM(initResponse);
            if (resyncSIM && self.anisetteDataOverride.count > 0 && self.anisetteResyncHandler) {
                NSError *resyncError = [self _resyncAnisetteWithSIM:resyncSIM];
                if (resyncError) {
                    completionHandler(resyncError, nil, nil, nil);
                    return;
                }
                clientData = [self _grandSlamClientData];
                initResponse = sendInitRequest(clientData);
                if (!initResponse) {
                    return;
                }
            }

            NSDictionary *initialResponseStatus = [initResponse objectForKey:@"Status"];
            if ([initialResponseStatus objectForKey:@"ec"] &&
                [[initialResponseStatus objectForKey:@"ec"] intValue] != 0) {
                // Error during request
                NSError *responseError = [self createError:[initialResponseStatus objectForKey:@"em"]
                                                          :[[initialResponseStatus objectForKey:@"ec"] intValue]];
                completionHandler(responseError, nil, nil, nil);
                return;
            }

            // MARK: AppleIDAuthSupport`stateClientNeg2
            // Generate the password key with the salt and interations requested by GSA

            size_t M_len = ccsrp_get_session_key_length(srp_ctx);
            char M_buf[M_len];

            NSString *respSP = initResponse[@"sp"];
            BOOL isS2K = [respSP isEqualToString:@"s2k"];
            addStringToNegProt(di_info, di_ctx, "|");
            if (respSP) addStringToNegProt(di_info, di_ctx, respSP.UTF8String);

            NSString *respC = initResponse[@"c"];
            NSData *respSalt = initResponse[@"s"];
            NSNumber *respIterations = initResponse[@"i"];
            NSData *bData = initResponse[@"B"];

            NSData *passKey = PBKDF2SRP(di_info, !isS2K, password, respSalt, respIterations);
            if (!passKey) {
                log_error("Could not generate password key!");
                NSError *error = [self createError:@"Could not generate password key" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            int result = ccsrp_client_process_challenge(srp_ctx,
                                                        username.UTF8String,
                                                        passKey.length, passKey.bytes,
                                                        respSalt.length, respSalt.bytes,
                                                        bData.bytes,
                                                        M_buf);
            if (result != 0) {
                log_error("Could not process challenge!");
                NSError *error = [self createError:@"Could not process challenge" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            NSData *MData = [NSData dataWithBytes:M_buf length:M_len];
            
            
            // 'Complete' response to GSA
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            __block NSDictionary *completeResponse = nil;
            [self _makeRequestWithParameters:@{
                @"c": respC,
                @"M1": MData,
                @"cpd": clientData,
                @"u": username,
                @"o": @"complete"
            } diagnosticContext:diagnosticContext completion:^(NSError *err, NSDictionary *response) {
                if (response) {
                    completeResponse = response;
                } else {
                    completionHandler(err, nil, nil, nil);
                }
                
                dispatch_semaphore_signal(semaphore);
            }];
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
            
            // Handle 'complete' response
            if (!completeResponse) {
                return;
            }
            
            NSDictionary *completeResponseStatus = [completeResponse objectForKey:@"Status"];
            NSInteger completeStatusCode = [[completeResponseStatus objectForKey:@"ec"] integerValue];
            NSString *outerAuthenticationMode = [completeResponseStatus objectForKey:@"au"];
            BOOL outerResponseRequiresTwoFactor = outerAuthenticationMode.length > 0 || completeStatusCode == 409;
            if ([completeResponseStatus objectForKey:@"ec"] &&
                completeStatusCode != 0) {
                // Don't error out just yet if 2FA has been requested
                // We need the idms token for that to be handled correctly
                
                if (outerResponseRequiresTwoFactor) {
                    // Ignore the error for now, because authentication is still required
                } else {
                    NSString *message = [completeResponseStatus objectForKey:@"em"] ?: @"Apple rejected the authentication request";
                    NSError *responseError = [self createError:message :(int)completeStatusCode];
                    completionHandler(responseError, nil, nil, nil);
                    return;
                }
            }

            // MARK: AppleIDAuthSupport`stateClientNeg3

            NSData *M2Data = completeResponse[@"M2"];
            if (!M2Data) {
                log_error("Missing M2 data!");
                NSError *error = [self createError:@"Missing M2 data" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }
            size_t data_len = M2Data.length;
            if (data_len != ccsrp_get_session_key_length(srp_ctx)) {
                log_error("Invalid M2 len!");
                NSError *error = [self createError:@"Invalid M2 len" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            if (!ccsrp_client_verify_session(srp_ctx, M2Data.bytes)) {
                log_error("Could not verify session!");
                NSError *error = [self createError:@"Could not verify session" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            addStringToNegProt(di_info, di_ctx, "|");

            NSData *spd = completeResponse[@"spd"];
            if (spd) {
                addDataToNegProt(di_info, di_ctx, spd);
            }
            addStringToNegProt(di_info, di_ctx, "|");

            NSData *sc = completeResponse[@"sc"];
            if (sc) {
                addDataToNegProt(di_info, di_ctx, sc);
            }
            addStringToNegProt(di_info, di_ctx, "|");

            NSData *negProto = completeResponse[@"np"];
            if (!negProto) {
                log_error("Neg proto missing!");
                NSError *error = [self createError:@"Neg proto missing" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            size_t digest_len = di_info->output_size;

            if (negProto.length != digest_len) {
                log_error("Neg proto hash too short");
                NSError *error = [self createError:@"Neg proto hash too short" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            unsigned char digest[digest_len];
            di_info->final(di_info, di_ctx, digest);

            unsigned char hmac_out[digest_len];
            NSData *hmacKey = createSessionKey(srp_ctx, "HMAC key:");
            cchmac(di_info,
                   hmacKey.length, hmacKey.bytes,
                   digest_len, digest,
                   hmac_out);

            if (cc_cmp_safe(digest_len, hmac_out, negProto.bytes)) {
                log_error("Invalid neg prot hmac!");
                NSError *error = [self createError:@"Invalid neg prot hmac" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            NSData *decrypted = decryptCBC(srp_ctx, spd);
            if (!decrypted) {
                log_error("Could not decrypt login response!");
                NSError *error = [self createError:@"Could not decrypt login response" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }
            NSDictionary *decryptedDict = [NSPropertyListSerialization propertyListWithData:decrypted options:0 format:nil error:nil];
            if (!decryptedDict) {
                log_error("Could not parse decrypted login response plist!");
                NSError *error = [self createError:@"Could not parse decrypted login response plist" :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            // MARK: AppleIDAuthSupport`AppleIDAuthSupportCopyAppTokensOptions

            NSString *adsid = decryptedDict[@"adsid"];
            NSString *acname = decryptedDict[@"acname"];
            NSString *idmsToken = decryptedDict[@"GsIdmsToken"];

            if (adsid.length == 0 || idmsToken.length == 0) {
                NSError *error = [self createError:@"Apple returned an incomplete authentication session"
                                                   :RPVInternalLoginError];
                completionHandler(error, nil, nil, nil);
                return;
            }

            // Some responses omit acname; use the SRP username as the fallback.
            NSString *accountName = acname.length > 0 ? acname : username;
            NSString *altDSID = [NSString stringWithFormat:@"%@|%@", adsid, accountName];
            
            log_debug("IDMS Token: %s", idmsToken.UTF8String);
            
            // Apple may describe 2FA in either the outer or decrypted response.
            NSInteger decryptedStatusCode = [decryptedDict[@"status-code"] integerValue];
            NSString *decryptedAuthenticationMode = [decryptedDict[@"url"] isKindOfClass:[NSString class]]
                ? decryptedDict[@"url"]
                : nil;
            BOOL requiresTwoFactor = outerResponseRequiresTwoFactor || decryptedStatusCode == 409;
            if (diagnosticContext) {
                RPV2FADiagnosticLog(@"login.session_metadata", @{
                    @"diagnostic_schema": @2,
                    @"trace_id": diagnosticContext[@"trace_id"],
                    @"requires_two_factor": @(requiresTwoFactor),
                    @"outer_auth_mode": RPVDiagnosticAuthMode(outerAuthenticationMode),
                    @"decrypted_auth_mode": RPVDiagnosticAuthMode(decryptedDict[@"url"]),
                    @"decrypted_status_code": @(decryptedStatusCode),
                    @"field_types": RPVDiagnosticFieldTypes(decryptedDict, @[@"adsid", @"acname", @"GsIdmsToken", @"sk", @"c", @"status-code", @"url"])
                });
            }

            // At this point, check if 2FA is required. If so, return with the idms token and adsid
            if (requiresTwoFactor) {
                NSString *authenticationMode = outerAuthenticationMode.length > 0
                    ? outerAuthenticationMode
                    : decryptedAuthenticationMode;
                
                int mode = [authenticationMode isEqualToString:@"trustedDeviceSecondaryAuth"] || authenticationMode.length == 0 ?
                    RPVInternalLogin2FARequiredTrustedDeviceError :
                    RPVInternalLogin2FARequiredSecondaryAuthError;

                RPV2FADiagnosticLog(@"login.two_factor_required", @{
                    @"mode": RPV2FAModeName(mode),
                    @"has_user_identity": @(altDSID.length > 0),
                    @"has_idms_token": @(idmsToken.length > 0)
                });
                
                NSString *message = [completeResponseStatus objectForKey:@"em"] ?: @"Two-factor authentication is required";
                NSError *responseError = [self createError:message :mode];
                
                completionHandler(responseError, altDSID, nil, idmsToken);
            } else {
            
                NSData *completeSK = decryptedDict[@"sk"];
                NSData *completeC = decryptedDict[@"c"];

                if (completeSK.length == 0 || completeC.length == 0) {
                    NSError *error = [self createError:@"Apple returned incomplete token credentials"
                                                       :RPVInternalLoginError];
                    completionHandler(error, nil, nil, nil);
                    return;
                }
                
                NSString *app = @"com.apple.gs.xcode.auth";
                NSArray<NSString *> *apps = @[app];

                NSData *checksum = createAppTokensChecksum(completeSK, adsid, apps);
                
                // 'Tokens' response to GSA
                semaphore = dispatch_semaphore_create(0);
                __block NSDictionary *tokensResponse = nil;
                [self _makeRequestWithParameters:@{
                    @"u": adsid,
                    @"app": apps,
                    @"c": completeC,
                    @"t": idmsToken,
                    @"checksum": checksum,
                    @"cpd": clientData,
                    @"o": @"apptokens"
                } diagnosticContext:diagnosticContext completion:^(NSError *err, NSDictionary *response) {
                    if (response) {
                        tokensResponse = response;
                    } else {
                        completionHandler(err, nil, nil, nil);
                    }
                    
                    dispatch_semaphore_signal(semaphore);
                }];
                dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                
                // Handle 'complete' response
                if (!tokensResponse) {
                    return;
                }
                
                NSDictionary *tokensResponseStatus = [tokensResponse objectForKey:@"Status"];
                if ([tokensResponseStatus objectForKey:@"ec"] &&
                    [[tokensResponseStatus objectForKey:@"ec"] intValue] != 0) {
                    // Error during request
                    NSError *responseError = [self createError:[tokensResponseStatus objectForKey:@"em"]
                                                              :[[tokensResponseStatus objectForKey:@"ec"] intValue]];
                    
                    completionHandler(responseError, nil, nil, nil);
                    return;
                }

                NSData *encryptedToken = tokensResponse[@"et"];
                NSData *decryptedToken = decryptGCM(completeSK, encryptedToken);
                if (!decryptedToken) {
                    log_error("Could not decrypt apptoken!");
                    NSError *error = [self createError:@"Could not decrypt apptoken" :RPVInternalLoginError];
                    completionHandler(error, nil, nil, nil);
                    return;
                }
                NSDictionary *decryptedTokDict = [NSPropertyListSerialization propertyListWithData:decryptedToken options:0 format:nil error:nil];
                if (!decryptedTokDict) {
                    log_error("Could not parse decrypted apptoken plist!");
                    NSError *error = [self createError:@"Could not parse decrypted apptoken plist" : RPVInternalLoginError];
                    completionHandler(error, nil, nil, nil);
                    return;
                }
                log_debug("Decrypted token dict: %s", decryptedTokDict.description.UTF8String);

                NSDictionary *tokenDict = decryptedTokDict[@"t"][app];
                NSString *token = tokenDict[@"token"];

                if (token.length == 0) {
                    NSError *error = [self createError:@"Apple did not return an application authentication token"
                                                       :RPVInternalLoginError];
                    completionHandler(error, nil, nil, nil);
                    return;
                }

                RPV2FADiagnosticLog(@"login.complete", @{
                    @"has_user_identity": @(altDSID.length > 0),
                    @"has_app_token": @(token.length > 0)
                });
                
                completionHandler(nil, altDSID, token, nil);
            }
        }
    }];
}

- (NSMutableDictionary<NSString *, NSString *> *)_twoFactorHeadersWithUserIdentity:(NSString *)userIdentity
                                                                          idmsToken:(NSString *)token {
    NSString *dsid = [userIdentity componentsSeparatedByString:@"|"].firstObject;
    if (dsid.length == 0 || token.length == 0) {
        return nil;
    }

    NSString *identityToken = [NSString stringWithFormat:@"%@:%@", dsid, token];
    NSString *encodedIdentityToken = [[identityToken dataUsingEncoding:NSUTF8StringEncoding]
        base64EncodedStringWithOptions:0];
    NSMutableDictionary<NSString *, NSString *> *headers = [@{
        @"Content-Type": @"text/x-xml-plist",
        @"User-Agent": self.userAgentOverride ?: @"akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0",
        @"Accept": @"text/x-xml-plist",
        @"Accept-Language": @"en-us",
        @"X-Apple-App-Info": @"com.apple.gs.xcode.auth",
        @"X-Apple-Client-App-Name": @"Xcode",
        @"X-Xcode-Version": @"14.2 (14C18)",
        @"X-Apple-Identity-Token": encodedIdentityToken,
    } mutableCopy];
    [headers addEntriesFromDictionary:[self _anisetteData]];
    [headers addEntriesFromDictionary:[self _deviceData]];
    if (self.clientInfoOverride.length > 0) {
        headers[@"X-MMe-Client-Info"] = self.clientInfoOverride;
    }
    return headers;
}

- (NSMutableURLRequest *)_twoFactorRequestWithURL:(NSURL *)URL
                                      userIdentity:(NSString *)userIdentity
                                         idmsToken:(NSString *)token {
    NSMutableDictionary<NSString *, NSString *> *headers =
        [self _twoFactorHeadersWithUserIdentity:userIdentity idmsToken:token];
    if (!URL || headers.count == 0) {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        [request setValue:value forHTTPHeaderField:key];
    }];
    return request;
}

- (NSMutableURLRequest *)_twoFactorJSONRequestWithURL:(NSURL *)URL
                                          userIdentity:(NSString *)userIdentity
                                             idmsToken:(NSString *)token {
    NSMutableURLRequest *request = [self _twoFactorRequestWithURL:URL
                                                      userIdentity:userIdentity
                                                         idmsToken:token];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    return request;
}

- (NSDictionary *)_twoFactorDictionaryFromData:(NSData *)data error:(NSError **)error {
    if (data.length == 0) {
        return nil;
    }

    NSError *plistError = nil;
    id object = [NSPropertyListSerialization propertyListWithData:data
                                                          options:0
                                                           format:nil
                                                            error:&plistError];
    if (![object isKindOfClass:[NSDictionary class]]) {
        NSError *JSONError = nil;
        object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&JSONError];
        if (![object isKindOfClass:[NSDictionary class]]) {
            if (error) {
                *error = JSONError ?: plistError;
            }
            return nil;
        }
    }
    return object;
}

- (NSArray<NSDictionary *> *)_twoFactorResponseContainers:(NSDictionary *)responseDictionary {
    if (![responseDictionary isKindOfClass:[NSDictionary class]]) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *containers = [NSMutableArray arrayWithObject:responseDictionary];
    for (NSString *key in @[@"Response", @"response", @"serverInfo", @"ServerInfo"]) {
        NSDictionary *container = responseDictionary[key];
        if ([container isKindOfClass:[NSDictionary class]]) {
            [containers addObject:container];
            NSDictionary *serverInfo = container[@"serverInfo"] ?: container[@"ServerInfo"];
            if ([serverInfo isKindOfClass:[NSDictionary class]]) {
                [containers addObject:serverInfo];
            }
        }
    }
    return containers;
}

- (NSDictionary<NSString *, NSString *> *)_twoFactorPhoneDescriptorFromResponseDictionary:(NSDictionary *)responseDictionary {
    NSArray<NSDictionary *> *containers = [self _twoFactorResponseContainers:responseDictionary];
    RPV2FADiagnosticLog(@"phone_descriptor.search_begin", @{
        @"root_keys": RPV2FASafeDictionaryKeys(responseDictionary),
        @"container_count": @(containers.count)
    });

    NSUInteger containerIndex = 0;
    for (NSDictionary *container in containers) {
        NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
        for (NSString *key in @[@"trustedPhoneNumber", @"phoneNumber"]) {
            NSDictionary *candidate = container[key];
            if ([candidate isKindOfClass:[NSDictionary class]]) {
                [candidates addObject:candidate];
            }
        }
        NSArray *trustedPhoneNumbers = container[@"trustedPhoneNumbers"];
        if ([trustedPhoneNumbers isKindOfClass:[NSArray class]]) {
            for (id candidate in trustedPhoneNumbers) {
                if ([candidate isKindOfClass:[NSDictionary class]]) {
                    [candidates addObject:candidate];
                }
            }
        }

        RPV2FADiagnosticLog(@"phone_descriptor.container", @{
            @"container_index": @(containerIndex),
            @"container_keys": RPV2FASafeDictionaryKeys(container),
            @"candidate_count": @(candidates.count)
        });

        NSUInteger candidateIndex = 0;
        for (NSDictionary *candidate in candidates) {
            id rawIdentifier = candidate[@"id"] ?: candidate[@"phoneNumber.id"];
            NSString *identifier = [rawIdentifier respondsToSelector:@selector(stringValue)]
                ? [rawIdentifier stringValue]
                : ([rawIdentifier isKindOfClass:[NSString class]] ? rawIdentifier : nil);
            NSString *rawDeliveryMode = candidate[@"pushMode"] ?: candidate[@"mode"] ?: container[@"mode"];
            NSString *safeDeliveryMode = [rawDeliveryMode.lowercaseString isEqualToString:@"voice"]
                ? @"voice"
                : ([rawDeliveryMode.lowercaseString isEqualToString:@"sms"] ? @"sms" : @"missing-or-other");
            RPV2FADiagnosticLog(@"phone_descriptor.candidate", @{
                @"container_index": @(containerIndex),
                @"candidate_index": @(candidateIndex),
                @"candidate_keys": RPV2FASafeDictionaryKeys(candidate),
                @"identifier_present": @(identifier.length > 0),
                @"identifier_type": rawIdentifier ? NSStringFromClass([rawIdentifier class]) : @"missing",
                @"delivery_mode": safeDeliveryMode
            });
            if (identifier.length == 0) {
                candidateIndex++;
                continue;
            }

            NSString *deliveryMode = rawDeliveryMode;
            deliveryMode = [deliveryMode.lowercaseString isEqualToString:@"voice"] ? @"voice" : @"sms";
            RPV2FADiagnosticLog(@"phone_descriptor.found", @{
                @"container_index": @(containerIndex),
                @"candidate_index": @(candidateIndex),
                @"delivery_mode": deliveryMode
            });
            return @{ @"id": identifier, @"mode": deliveryMode };
        }
        containerIndex++;
    }
    RPV2FADiagnosticLog(@"phone_descriptor.not_found", nil);
    return nil;
}

- (NSNumber *)_twoFactorErrorCodeFromResponseDictionary:(NSDictionary *)responseDictionary {
    NSNumber *successCode = nil;
    for (NSDictionary *container in [self _twoFactorResponseContainers:responseDictionary]) {
        NSMutableArray *codes = [@[
                             container[@"ec"] ?: NSNull.null,
                             container[@"code"] ?: NSNull.null,
                             [container[@"Status"] isKindOfClass:[NSDictionary class]]
                                ? container[@"Status"][@"ec"] ?: NSNull.null
                                : NSNull.null] mutableCopy];
        for (NSString *key in @[@"service_errors", @"serviceErrors"]) {
            NSArray *errors = container[key];
            if (![errors isKindOfClass:[NSArray class]]) continue;
            for (id entry in errors) {
                if ([entry isKindOfClass:[NSDictionary class]] && entry[@"code"]) {
                    [codes addObject:entry[@"code"]];
                }
            }
        }
        for (id rawCode in codes) {
            NSString *text = [rawCode isKindOfClass:[NSNumber class]] ? [rawCode stringValue]
                : ([rawCode isKindOfClass:[NSString class]] ? rawCode : nil);
            if (text.length == 0) continue;
            NSScanner *scanner = [NSScanner scannerWithString:text];
            long long value = 0;
            if (![scanner scanLongLong:&value] || !scanner.isAtEnd) continue;
            // A nested service error takes precedence over outer ec=0.
            if (value != 0) return @(value);
            successCode = @0;
        }
    }
    return successCode;
}

- (NSString *)_twoFactorErrorMessageFromResponseDictionary:(NSDictionary *)responseDictionary {
    for (NSDictionary *container in [self _twoFactorResponseContainers:responseDictionary]) {
        for (NSString *key in @[@"em", @"message", @"userString", @"title"]) {
            NSString *message = container[key];
            if ([message isKindOfClass:[NSString class]] && message.length > 0) {
                return message;
            }
        }

        NSArray *serviceErrors = container[@"service_errors"] ?: container[@"serviceErrors"];
        NSDictionary *firstServiceError = [serviceErrors isKindOfClass:[NSArray class]] ? serviceErrors.firstObject : nil;
        for (NSString *key in @[@"message", @"title"]) {
            NSString *message = [firstServiceError isKindOfClass:[NSDictionary class]] ? firstServiceError[key] : nil;
            if ([message isKindOfClass:[NSString class]] && message.length > 0) {
                return message;
            }
        }
    }
    return nil;
}

- (NSError *)_twoFactorServerErrorForData:(NSData *)data
                                  response:(NSURLResponse *)response
                            transportError:(NSError *)transportError {
    if (transportError) {
        return transportError;
    }
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        return [self createError:@"Apple returned an invalid authentication response" :RPVInternalLoginError];
    }

    NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
    NSDictionary *responseDictionary = [self _twoFactorDictionaryFromData:data error:nil];
    NSNumber *appleCode = [self _twoFactorErrorCodeFromResponseDictionary:responseDictionary];
    RPV2FADiagnosticLog(@"two_factor.server_result", @{
        @"http_status": @(statusCode),
        @"apple_code_present": @(appleCode != nil),
        @"apple_code": appleCode ?: @0,
        @"parsed_dictionary": @(responseDictionary != nil),
        @"root_keys": RPV2FASafeDictionaryKeys(responseDictionary)
    });
    if (appleCode.integerValue == -21669) {
        return [self createError:@"Incorrect 2FA code" :RPVInternalLoginIncorrect2FACodeError];
    }

    if (statusCode < 200 || statusCode >= 300 || (appleCode && appleCode.integerValue != 0)) {
        NSString *message = [self _twoFactorErrorMessageFromResponseDictionary:responseDictionary];
        if (message.length == 0) {
            message = statusCode < 200 || statusCode >= 300
                ? [NSString stringWithFormat:@"Apple rejected the authentication request (HTTP %ld)", (long)statusCode]
                : @"Apple rejected the authentication request";
        }
        NSInteger errorCode = appleCode.integerValue != 0 ? appleCode.integerValue : statusCode;
        return [self createError:message :(int)(errorCode ?: RPVInternalLoginError)];
    }
    // Trusted-phone endpoints allow an empty 2xx, but not an HTML page.
    if (data.length > 0 && !responseDictionary) {
        return [self createError:@"Apple returned an unreadable authentication response. Please try again later."
                               :RPVInternalLoginError];
    }
    return nil;
}

- (void)_checkAuthEndpointWithUserIdentity:(NSString *)userIdentity
                                  idmsToken:(NSString *)token
                             andCompletion:(void (^)(NSError *error, NSDictionary<NSString *, NSString *> *phoneDescriptor))completionHandler {
    NSURL *URL = self.lookupURLs
        ? [NSURL URLWithString:self.lookupURLs[@"secondaryAuth"]]
        : [NSURL URLWithString:@"https://gsa.apple.com/auth"];
    // Trusted-phone endpoints use JSON content negotiation.
    NSMutableURLRequest *request = [self _twoFactorJSONRequestWithURL:URL
                                                          userIdentity:userIdentity
                                                             idmsToken:token];
    RPV2FADiagnosticLog(@"auth_metadata.request", @{
        @"endpoint": RPV2FASafeEndpoint(URL),
        @"request_created": @(request != nil),
        @"lookup_url_present": @(self.lookupURLs[@"secondaryAuth"] != nil)
    });
    if (!request) {
        completionHandler([self createError:@"The Apple authentication session is incomplete" :RPVInternalLoginError], nil);
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        RPV2FADiagnosticLog(@"auth_metadata.response", RPV2FASafeResponseSummary(data, response, error));
        NSError *serverError = [self _twoFactorServerErrorForData:data response:response transportError:error];
        if (serverError) {
            RPV2FADiagnosticLog(@"auth_metadata.failed", @{
                @"error_domain": serverError.domain ?: @"unknown",
                @"error_code": @(serverError.code)
            });
            completionHandler(serverError, nil);
            return;
        }

        NSError *parseError = nil;
        NSDictionary *responseDictionary = [self _twoFactorDictionaryFromData:data error:&parseError];
        RPV2FADiagnosticLog(@"auth_metadata.parsed", @{
            @"parsed_dictionary": @(responseDictionary != nil),
            @"parse_error_domain": parseError.domain ?: @"none",
            @"parse_error_code": @(parseError ? parseError.code : 0),
            @"root_keys": RPV2FASafeDictionaryKeys(responseDictionary)
        });
        NSDictionary *phoneDescriptor = [self _twoFactorPhoneDescriptorFromResponseDictionary:responseDictionary];
        if (!phoneDescriptor) {
            RPV2FADiagnosticLog(@"auth_metadata.no_usable_phone", nil);
            completionHandler([self createError:@"Apple did not return a usable trusted phone number"
                                               :RPVInternalLoginError], nil);
            return;
        }
        RPV2FADiagnosticLog(@"auth_metadata.complete", @{
            @"delivery_mode": phoneDescriptor[@"mode"] ?: @"missing"
        });
        completionHandler(nil, phoneDescriptor);
    }] resume];
}

- (void)_performTwoFactorCodeRequest:(NSMutableURLRequest *)request
                          completion:(void (^)(NSError *error))completionHandler {
    if (!request) {
        completionHandler([self createError:@"The Apple authentication request could not be created"
                                           :RPVInternalLoginError]);
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        RPV2FADiagnosticLog(@"code_request.response", RPV2FASafeResponseSummary(data, response, error));
        NSError *serverError = [self _twoFactorServerErrorForData:data response:response transportError:error];
        RPV2FADiagnosticLog(serverError ? @"code_request.failed" : @"code_request.complete", serverError ? @{
            @"error_domain": serverError.domain ?: @"unknown",
            @"error_code": @(serverError.code)
        } : nil);
        completionHandler(serverError);
    }] resume];
}

- (void)requestTwoFactorCodeWithUserIdentity:(NSString *)userIdentity
                                    idmsToken:(NSString *)token
                                         mode:(int)mode
                                andCompletion:(void (^)(NSError *error))completionHandler {
    RPV2FADiagnosticLog(@"code_request.begin", @{
        @"mode": RPV2FAModeName(mode),
        @"cached_phone_descriptor": @(self.twoFactorPhoneNumberID.length > 0 && self.twoFactorPhoneDeliveryMode.length > 0)
    });
    if (mode == RPVInternalLogin2FARequiredTrustedDeviceError) {
        self.twoFactorPhoneNumberID = nil;
        self.twoFactorPhoneDeliveryMode = nil;
        NSURL *URL = self.lookupURLs
            ? [NSURL URLWithString:self.lookupURLs[@"trustedDeviceSecondaryAuth"]]
            : [NSURL URLWithString:@"https://gsa.apple.com/auth/verify/trusteddevice"];
        NSMutableURLRequest *request = [self _twoFactorRequestWithURL:URL
                                                         userIdentity:userIdentity
                                                            idmsToken:token];
        RPV2FADiagnosticLog(@"code_request.prepared", @{
            @"mode": RPV2FAModeName(mode),
            @"endpoint": RPV2FASafeEndpoint(URL),
            @"request_created": @(request != nil)
        });
        [self _performTwoFactorCodeRequest:request completion:completionHandler];
        return;
    }

    if (mode != RPVInternalLogin2FARequiredSecondaryAuthError) {
        completionHandler([self createError:@"Apple returned an unsupported two-factor authentication mode"
                                           :RPVInternalLoginError]);
        return;
    }

    [self _checkAuthEndpointWithUserIdentity:userIdentity
                                    idmsToken:token
                               andCompletion:^(NSError *error, NSDictionary<NSString *,NSString *> *phoneDescriptor) {
        if (error) {
            completionHandler(error);
            return;
        }

        NSString *phoneNumberID = phoneDescriptor[@"id"];
        NSString *deliveryMode = phoneDescriptor[@"mode"];
        self.twoFactorPhoneNumberID = phoneNumberID;
        self.twoFactorPhoneDeliveryMode = deliveryMode;

        NSURL *URL = [NSURL URLWithString:@"https://gsa.apple.com/auth/verify/phone"];
        NSMutableURLRequest *request = [self _twoFactorJSONRequestWithURL:URL
                                                              userIdentity:userIdentity
                                                                 idmsToken:token];
        request.HTTPMethod = @"PUT";
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
            @"phoneNumber": @{ @"id": @([phoneNumberID integerValue]) },
            @"mode": deliveryMode
        } options:0 error:nil];
        RPV2FADiagnosticLog(@"code_request.prepared", @{
            @"mode": RPV2FAModeName(mode),
            @"endpoint": RPV2FASafeEndpoint(request.URL),
            @"delivery_mode": deliveryMode ?: @"missing",
            @"request_created": @(request != nil)
        });
        [self _performTwoFactorCodeRequest:request completion:completionHandler];
    }];
}

- (NSMutableURLRequest *)_twoFactorCodeSubmissionRequest:(NSString *)code
                                            userIdentity:(NSString *)userIdentity
                                               idmsToken:(NSString *)token
                                                    mode:(int)mode
                                         phoneDescriptor:(NSDictionary<NSString *, NSString *> *)phoneDescriptor {
    NSMutableURLRequest *request = nil;
    if (mode == RPVInternalLogin2FARequiredSecondaryAuthError) {
        NSString *phoneNumberID = phoneDescriptor[@"id"];
        NSString *deliveryMode = phoneDescriptor[@"mode"];
        if (phoneNumberID.length == 0 || deliveryMode.length == 0) {
            return nil;
        }
        NSURL *URL = [NSURL URLWithString:@"https://gsa.apple.com/auth/verify/phone/securitycode"];
        request = [self _twoFactorJSONRequestWithURL:URL userIdentity:userIdentity idmsToken:token];
        request.HTTPMethod = @"POST";
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
            @"securityCode": @{ @"code": code },
            @"phoneNumber": @{ @"id": @([phoneNumberID integerValue]) },
            @"mode": deliveryMode
        } options:0 error:nil];
    } else if (mode == RPVInternalLogin2FARequiredTrustedDeviceError) {
        NSURL *URL = self.lookupURLs
            ? [NSURL URLWithString:self.lookupURLs[@"validateCode"]]
            : [NSURL URLWithString:@"https://gsa.apple.com/grandslam/GsService2/validate"];
        request = [self _twoFactorRequestWithURL:URL userIdentity:userIdentity idmsToken:token];
        [request setValue:code forHTTPHeaderField:@"security-code"];
    }
    return request;
}

- (void)_performTwoFactorCodeSubmission:(NSString *)code
                           userIdentity:(NSString *)userIdentity
                              idmsToken:(NSString *)token
                                   mode:(int)mode
                        phoneDescriptor:(NSDictionary<NSString *, NSString *> *)phoneDescriptor
                             completion:(RPVTwoFactorResultBlock)completionHandler {
    NSMutableURLRequest *request = [self _twoFactorCodeSubmissionRequest:code
                                                            userIdentity:userIdentity
                                                               idmsToken:token
                                                                    mode:mode
                                                         phoneDescriptor:phoneDescriptor];

    if (!request) {
        completionHandler([self createError:@"The Apple authentication request could not be created"
                                           :RPVInternalLoginError]);
        return;
    }

    RPV2FADiagnosticLog(@"code_submit.prepared", @{
        @"mode": RPV2FAModeName(mode),
        @"endpoint": RPV2FASafeEndpoint(request.URL),
        @"request_created": @YES
    });

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        RPV2FADiagnosticLog(@"code_submit.response", RPV2FASafeResponseSummary(data, response, error));
        NSError *serverError = [self _twoFactorServerErrorForData:data response:response transportError:error];
        if (serverError) {
            RPV2FADiagnosticLog(@"code_submit.failed", @{
                @"error_domain": serverError.domain ?: @"unknown",
                @"error_code": @(serverError.code)
            });
            completionHandler(serverError);
            return;
        }

        // Phone validation may report success with an empty 2xx response.
        if (data.length > 0 && ![self _twoFactorDictionaryFromData:data error:nil]) {
            RPV2FADiagnosticLog(@"code_submit.unreadable_response", nil);
            completionHandler([self createError:@"Apple returned an unreadable authentication response"
                                               :RPVInternalLoginError]);
            return;
        }
        RPV2FADiagnosticLog(@"code_submit.complete", nil);
        completionHandler(nil);
    }] resume];
}

- (void)submitTwoFactorCode:(NSString *)code
           withUserIdentity:(NSString *)userIdentity
                  idmsToken:(NSString *)token
                       mode:(int)mode
              andCompletion:(RPVTwoFactorResultBlock)completionHandler {
    NSString *normalizedCode = RPVNormalizedVerificationCode(code ?: @"");
    RPV2FADiagnosticLog(@"code_submit.begin", @{
        @"mode": RPV2FAModeName(mode),
        @"code_length": @(normalizedCode.length),
        @"cached_phone_descriptor": @(self.twoFactorPhoneNumberID.length > 0 && self.twoFactorPhoneDeliveryMode.length > 0)
    });
    if (normalizedCode.length != 6) {
        completionHandler([self createError:@"The verification code must contain exactly six digits"
                                           :RPVInternalLoginInvalid2FAFormatError]);
        return;
    }

    if (mode != RPVInternalLogin2FARequiredSecondaryAuthError) {
        [self _performTwoFactorCodeSubmission:normalizedCode
                                 userIdentity:userIdentity
                                    idmsToken:token
                                         mode:mode
                              phoneDescriptor:nil
                                   completion:completionHandler];
        return;
    }

    if (self.twoFactorPhoneNumberID.length > 0 && self.twoFactorPhoneDeliveryMode.length > 0) {
        [self _performTwoFactorCodeSubmission:normalizedCode
                                 userIdentity:userIdentity
                                    idmsToken:token
                                         mode:mode
                              phoneDescriptor:@{
                                  @"id": self.twoFactorPhoneNumberID,
                                  @"mode": self.twoFactorPhoneDeliveryMode
                              }
                                   completion:completionHandler];
        return;
    }

    [self _checkAuthEndpointWithUserIdentity:userIdentity
                                    idmsToken:token
                               andCompletion:^(NSError *error, NSDictionary<NSString *,NSString *> *phoneDescriptor) {
        if (error) {
            completionHandler(error);
            return;
        }
        self.twoFactorPhoneNumberID = phoneDescriptor[@"id"];
        self.twoFactorPhoneDeliveryMode = phoneDescriptor[@"mode"];
        [self _performTwoFactorCodeSubmission:normalizedCode
                                 userIdentity:userIdentity
                                    idmsToken:token
                                         mode:mode
                              phoneDescriptor:phoneDescriptor
                                   completion:completionHandler];
    }];
}

@end
