#import "RPVRemoteAnisetteProvider.h"

#import <corecrypto/ccdigest.h>
#import <corecrypto/ccsha2.h>

static NSString *const RPVAnisetteErrorDomain = @"jp.soh.reprovision.anisette";
static NSString *const RPVAnisetteProviderURL = @"https://ani.sidestore.io";
static NSString *const RPVAnisetteUUIDKey = @"RPVAnisetteLocalUserUUID";
static NSString *const RPVAnisetteProvisioningKey = @"RPVAnisetteProvisioningInfo";
static NSString *const RPVAnisetteRoutingInfoKey = @"RPVAnisetteRoutingInfo";

static NSError *RPVAnisetteError(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:RPVAnisetteErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description ?: @"Anisette request failed"}];
}

static NSString *RPVSHA256String(NSString *string) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    const struct ccdigest_info *digestInfo = ccsha256_di();
    unsigned char digest[digestInfo->output_size];
    ccdigest(digestInfo, data.length, data.bytes, digest);

    NSMutableString *result = [NSMutableString stringWithCapacity:digestInfo->output_size * 2];
    for (size_t index = 0; index < digestInfo->output_size; index++) {
        [result appendFormat:@"%02X", digest[index]];
    }
    return result;
}

@interface RPVRemoteAnisetteProvider () <NSURLSessionWebSocketDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSUUID *localUserUUID;
@property (nonatomic, copy) NSString *localUserID;
@property (nonatomic, copy) NSString *clientInfo;
@property (nonatomic, copy) NSData *cachedProvisioningInfo;
@property (nonatomic, copy) NSString *cachedRoutingInfo;
@property (nonatomic, strong) NSURLSessionWebSocketTask *openingWebSocketTask;
@property (nonatomic, copy) void (^webSocketOpenCompletion)(NSURLSessionWebSocketTask *task, NSError *error);
@end

@implementation RPVRemoteAnisetteProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 20.0;
        configuration.timeoutIntervalForResource = 60.0;
        configuration.waitsForConnectivity = YES;
        self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:nil];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *uuidString = [defaults stringForKey:RPVAnisetteUUIDKey];
        self.localUserUUID = uuidString ? [[NSUUID alloc] initWithUUIDString:uuidString] : nil;
        if (!self.localUserUUID) {
            self.localUserUUID = [NSUUID UUID];
            [defaults setObject:self.localUserUUID.UUIDString forKey:RPVAnisetteUUIDKey];
        }
        self.localUserID = RPVSHA256String(self.localUserUUID.UUIDString);

        // A cached ADI identity may already have a persisted GS token bound to
        // it from an earlier app launch. Treat it as pinned by default; a new
        // user-initiated login explicitly unpins it before GrandSlam starts.
        self.cachedProvisioningInfo = [defaults dataForKey:RPVAnisetteProvisioningKey];
        self.cachedRoutingInfo = [defaults stringForKey:RPVAnisetteRoutingInfoKey];
        self.identityPinned = self.cachedProvisioningInfo.length > 0 && self.cachedRoutingInfo.length > 0;
    }
    return self;
}

- (void)finishOpeningWebSocketTask:(NSURLSessionWebSocketTask *)task error:(NSError *)error {
    __block void (^completion)(NSURLSessionWebSocketTask *, NSError *) = nil;
    @synchronized (self) {
        if (task == self.openingWebSocketTask && self.webSocketOpenCompletion) {
            completion = self.webSocketOpenCompletion;
            self.webSocketOpenCompletion = nil;
            self.openingWebSocketTask = nil;
        }
    }
    if (completion) {
        completion(error ? nil : task, error);
    }
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
 didOpenWithProtocol:(NSString *)protocol API_AVAILABLE(ios(13.0)) {
    [self finishOpeningWebSocketTask:webSocketTask error:nil];
}

- (void)URLSession:(NSURLSession *)session
      webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
             reason:(NSData *)reason API_AVAILABLE(ios(13.0)) {
    NSError *error = RPVAnisetteError(16, @"The anisette provisioning socket closed before it was ready");
    [self finishOpeningWebSocketTask:webSocketTask error:error];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error && [task isKindOfClass:[NSURLSessionWebSocketTask class]]) {
        [self finishOpeningWebSocketTask:(NSURLSessionWebSocketTask *)task error:error];
    }
}

- (void)openProvisioningWebSocketWithCompletion:(void (^)(NSURLSessionWebSocketTask *task, NSError *error))completion API_AVAILABLE(ios(13.0)) {
    NSURL *URL = [NSURL URLWithString:[RPVAnisetteProviderURL stringByAppendingString:@"/v3/provisioning_session"]];
    NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    components.scheme = @"wss";
    NSURLSessionWebSocketTask *task = [self.session webSocketTaskWithURL:components.URL];

    @synchronized (self) {
        self.openingWebSocketTask = task;
        self.webSocketOpenCompletion = completion;
    }

    [task resume];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL stillOpening = NO;
        @synchronized (self) {
            stillOpening = (task == self.openingWebSocketTask && self.webSocketOpenCompletion != nil);
        }
        if (!stillOpening) {
            return;
        }
        NSError *timeout = [NSError errorWithDomain:NSURLErrorDomain
                                               code:NSURLErrorTimedOut
                                           userInfo:@{NSLocalizedDescriptionKey: @"The anisette provisioning socket timed out"}];
        [self finishOpeningWebSocketTask:task error:timeout];
        if (task.state == NSURLSessionTaskStateRunning) {
            [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        }
    });
}

- (NSData *)localUserUUIDData {
    uuid_t bytes;
    [self.localUserUUID getUUIDBytes:bytes];
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

- (void)fetchClientInfoWithCompletion:(void (^)(NSError *error))completion {
    if (self.clientInfo.length > 0) {
        completion(nil);
        return;
    }

    NSURL *URL = [NSURL URLWithString:[RPVAnisetteProviderURL stringByAppendingString:@"/v3/client_info"]];
    [[self.session dataTaskWithURL:URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data || [(NSHTTPURLResponse *)response statusCode] != 200) {
            completion(error ?: RPVAnisetteError(1, @"Could not fetch anisette client information"));
            return;
        }

        NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        NSString *clientInfo = JSON[@"client_info"] ?: JSON[@"clientInfo"];
        if (![clientInfo isKindOfClass:[NSString class]] || clientInfo.length == 0) {
            completion(error ?: RPVAnisetteError(2, @"The anisette provider returned invalid client information"));
            return;
        }
        self.clientInfo = clientInfo;
        completion(nil);
    }] resume];
}

- (void)sendAppleProvisioningRequestToURL:(NSString *)URLString
                                   values:(NSDictionary *)values
                               completion:(void (^)(NSDictionary *response, NSError *error))completion {
    NSDictionary *body = @{ @"Header": @{}, @"Request": values ?: @{} };
    NSError *serializationError = nil;
    NSData *bodyData = [NSPropertyListSerialization dataWithPropertyList:body
                                                                  format:NSPropertyListXMLFormat_v1_0
                                                                 options:0
                                                                   error:&serializationError];
    if (!bodyData) {
        completion(nil, serializationError);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:URLString]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    [request setValue:@"text/x-xml-plist" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"en_US" forHTTPHeaderField:@"Accept-Language"];
    [request setValue:@"akd/1.0 CFNetwork/978.0.7 Darwin/18.7.0" forHTTPHeaderField:@"User-Agent"];
    [request setValue:self.localUserID forHTTPHeaderField:@"X-Apple-I-MD-LU"];
    [request setValue:self.clientInfo forHTTPHeaderField:@"X-MMe-Client-Info"];
    [request setValue:self.localUserUUID.UUIDString forHTTPHeaderField:@"X-Mme-Device-Id"];
    NSString *country = NSLocale.currentLocale.countryCode;
    if (country.length > 0) {
        [request setValue:country forHTTPHeaderField:@"X-MMe-Country"];
    }

    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data || [(NSHTTPURLResponse *)response statusCode] != 200) {
            completion(nil, error ?: RPVAnisetteError(3, @"Apple anisette provisioning was unavailable"));
            return;
        }

        NSDictionary *root = [NSPropertyListSerialization propertyListWithData:data
                                                                        options:0
                                                                         format:nil
                                                                          error:&error];
        NSDictionary *operationResponse = root[@"Response"];
        NSInteger resultCode = [operationResponse[@"Status"][@"ec"] integerValue];
        if (![operationResponse isKindOfClass:[NSDictionary class]] || resultCode != 0) {
            completion(nil, error ?: RPVAnisetteError(resultCode ?: 4, @"Apple rejected anisette provisioning"));
            return;
        }
        completion(operationResponse, nil);
    }] resume];
}

- (void)receiveJSONFromWebSocket:(NSURLSessionWebSocketTask *)task
                      completion:(void (^)(NSDictionary *JSON, NSError *error))completion API_AVAILABLE(ios(13.0)) {
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) {
        if (error || !message) {
            completion(nil, error ?: RPVAnisetteError(5, @"The anisette provisioning session ended early"));
            return;
        }
        NSData *data = message.data ?: [message.string dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *JSON = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
        completion([JSON isKindOfClass:[NSDictionary class]] ? JSON : nil,
                   JSON ? nil : (error ?: RPVAnisetteError(6, @"The anisette provider returned invalid data")));
    }];
}

- (void)sendJSON:(NSDictionary *)JSON
      toWebSocket:(NSURLSessionWebSocketTask *)task
       completion:(void (^)(NSError *error))completion API_AVAILABLE(ios(13.0)) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:JSON options:0 error:&error];
    if (!data) {
        completion(error);
        return;
    }
    NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:string]
    completionHandler:completion];
}

- (BOOL)message:(NSDictionary *)message hasResult:(NSString *)result {
    return [message[@"result"] isEqualToString:result];
}

- (void)performRemoteProvisioningWithSPIM:(NSData *)SPIM
                               completion:(void (^)(NSData *provisioningInfo, NSString *routingInfo, NSError *error))completion API_AVAILABLE(ios(13.0)) {
    [self openProvisioningWebSocketWithCompletion:^(NSURLSessionWebSocketTask *task, NSError *openError) {
        if (openError || !task) {
            completion(nil, nil, openError ?: RPVAnisetteError(17, @"The anisette provisioning socket did not open"));
            return;
        }
        [self receiveJSONFromWebSocket:task completion:^(NSDictionary *first, NSError *error) {
        if (error || ![self message:first hasResult:@"GiveIdentifier"]) {
            completion(nil, nil, error ?: RPVAnisetteError(7, @"Unexpected anisette provisioning handshake"));
            return;
        }
        NSString *identifier = [[self localUserUUIDData] base64EncodedStringWithOptions:0];
        [self sendJSON:@{ @"identifier": identifier } toWebSocket:task completion:^(NSError *error) {
            if (error) { completion(nil, nil, error); return; }
            [self receiveJSONFromWebSocket:task completion:^(NSDictionary *second, NSError *error) {
                if (error || ![self message:second hasResult:@"GiveStartProvisioningData"]) {
                    completion(nil, nil, error ?: RPVAnisetteError(8, @"Unexpected anisette start request"));
                    return;
                }
                [self sendJSON:@{ @"spim": [SPIM base64EncodedStringWithOptions:0] }
                    toWebSocket:task completion:^(NSError *error) {
                    if (error) { completion(nil, nil, error); return; }
                    [self receiveJSONFromWebSocket:task completion:^(NSDictionary *third, NSError *error) {
                        NSString *CPIMString = third[@"cpim"];
                        NSData *CPIM = [CPIMString isKindOfClass:[NSString class]] ?
                            [[NSData alloc] initWithBase64EncodedString:CPIMString options:0] : nil;
                        if (error || ![self message:third hasResult:@"GiveEndProvisioningData"] || !CPIM) {
                            completion(nil, nil, error ?: RPVAnisetteError(9, @"The anisette provider did not produce CPIM data"));
                            return;
                        }

                        [self sendAppleProvisioningRequestToURL:@"https://gsa.apple.com/grandslam/MidService/finishMachineProvisioning"
                                                        values:@{ @"cpim": [CPIM base64EncodedStringWithOptions:0] }
                                                    completion:^(NSDictionary *response, NSError *error) {
                            NSString *PTMString = response[@"ptm"];
                            NSString *TKString = response[@"tk"];
                            NSString *routingInfo = [response[@"X-Apple-I-MD-RINFO"] description];
                            NSData *PTM = [PTMString isKindOfClass:[NSString class]] ?
                                [[NSData alloc] initWithBase64EncodedString:PTMString options:0] : nil;
                            NSData *TK = [TKString isKindOfClass:[NSString class]] ?
                                [[NSData alloc] initWithBase64EncodedString:TKString options:0] : nil;
                            if (error || !PTM || !TK || routingInfo.length == 0) {
                                completion(nil, nil, error ?: RPVAnisetteError(10, @"Apple returned incomplete provisioning data"));
                                return;
                            }

                            [self sendJSON:@{
                                @"ptm": [PTM base64EncodedStringWithOptions:0],
                                @"tk": [TK base64EncodedStringWithOptions:0]
                            } toWebSocket:task completion:^(NSError *error) {
                                if (error) { completion(nil, nil, error); return; }
                                [self receiveJSONFromWebSocket:task completion:^(NSDictionary *final, NSError *error) {
                                    NSString *provisioningString = final[@"adi_pb"] ?: final[@"adiPb"];
                                    NSData *provisioningInfo = [provisioningString isKindOfClass:[NSString class]] ?
                                        [[NSData alloc] initWithBase64EncodedString:provisioningString options:0] : nil;
                                    [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
                                    if (error || ![self message:final hasResult:@"ProvisioningSuccess"] || !provisioningInfo) {
                                        completion(nil, nil, error ?: RPVAnisetteError(11, @"Anisette provisioning did not complete"));
                                        return;
                                    }
                                    completion(provisioningInfo, routingInfo, nil);
                                }];
                            }];
                        }];
                    }];
                }];
            }];
        }];
        }];
    }];
}

- (void)provisionWithCompletion:(void (^)(NSData *provisioningInfo, NSString *routingInfo, NSError *error))completion {
    [self sendAppleProvisioningRequestToURL:@"https://gsa.apple.com/grandslam/MidService/startMachineProvisioning"
                                    values:@{}
                                completion:^(NSDictionary *response, NSError *error) {
        NSString *SPIMString = response[@"spim"];
        NSData *SPIM = [SPIMString isKindOfClass:[NSString class]] ?
            [[NSData alloc] initWithBase64EncodedString:SPIMString options:0] : nil;
        if (error || !SPIM) {
            completion(nil, nil, error ?: RPVAnisetteError(12, @"Apple returned incomplete start-provisioning data"));
            return;
        }
        if (@available(iOS 13.0, *)) {
            [self performRemoteProvisioningWithSPIM:SPIM completion:completion];
        } else {
            completion(nil, nil, RPVAnisetteError(13, @"Remote anisette requires iOS 13 or newer"));
        }
    }];
}

- (NSDictionary *)headersFromJSON:(NSDictionary *)JSON routingInfo:(NSString *)storedRoutingInfo error:(NSError **)error {
    NSString *machineID = JSON[@"X-Apple-I-MD-M"];
    NSString *OTP = JSON[@"X-Apple-I-MD"];
    NSString *routingInfo = [JSON[@"X-Apple-I-MD-RINFO"] description] ?: storedRoutingInfo;
    if (machineID.length == 0 || OTP.length == 0 || routingInfo.length == 0 || self.clientInfo.length == 0) {
        if (error) *error = RPVAnisetteError(14, @"The anisette provider returned incomplete headers");
        return nil;
    }

    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    NSString *locale = NSLocale.currentLocale.localeIdentifier ?: @"en_US";
    NSString *timeZone = NSTimeZone.localTimeZone.abbreviation ?: @"UTC";

    return @{
        @"X-Apple-I-MD-M": machineID,
        @"X-Apple-I-MD": OTP,
        @"X-Apple-I-MD-LU": self.localUserID,
        @"X-Apple-I-MD-RINFO": routingInfo,
        @"X-Mme-Device-Id": self.localUserUUID.UUIDString,
        @"X-MMe-Client-Info": self.clientInfo,
        @"X-Apple-I-Client-Time": [formatter stringFromDate:[NSDate date]],
        @"X-Apple-Locale": locale,
        @"X-Apple-I-Locale": locale,
        @"X-Apple-I-TimeZone": timeZone,
        @"X-Apple-I-SRL-NO": @"0"
    };
}

- (void)requestHeadersWithProvisioningInfo:(NSData *)provisioningInfo
                               routingInfo:(NSString *)routingInfo
                                completion:(void (^)(NSDictionary *headers, NSError *error))completion {
    NSDictionary *body = @{
        @"identifier": [self.localUserUUIDData base64EncodedStringWithOptions:0],
        @"adi_pb": [provisioningInfo base64EncodedStringWithOptions:0]
    };
    NSError *error = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];
    if (!bodyData) { completion(nil, error); return; }

    NSURL *URL = [NSURL URLWithString:[RPVAnisetteProviderURL stringByAppendingString:@"/v3/get_headers"]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data || [(NSHTTPURLResponse *)response statusCode] != 200) {
            completion(nil, error ?: RPVAnisetteError(15, @"Could not generate anisette headers"));
            return;
        }
        NSDictionary *JSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        NSDictionary *headers = [self headersFromJSON:JSON routingInfo:routingInfo error:&error];
        completion(headers, error);
    }] resume];
}

- (void)provisionAndFetchWithCompletion:(void (^)(NSDictionary *headers, NSError *error))completion {
    [self provisionWithCompletion:^(NSData *provisioningInfo, NSString *routingInfo, NSError *error) {
        if (error || !provisioningInfo) { completion(nil, error); return; }
        // Retain the ADI identity in memory before writing it to preferences.
        // A user can lock the device immediately after tapping Sign, and the
        // active signing pass must not lose or replace the machine identity
        // that its GS token is bound to during that transition.
        self.cachedProvisioningInfo = provisioningInfo;
        self.cachedRoutingInfo = routingInfo;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setObject:provisioningInfo forKey:RPVAnisetteProvisioningKey];
        [defaults setObject:routingInfo forKey:RPVAnisetteRoutingInfoKey];
        [defaults synchronize];
        [self requestHeadersWithProvisioningInfo:provisioningInfo routingInfo:routingInfo completion:completion];
    }];
}

- (void)fetchAnisetteDataOnceWithCompletion:(void (^)(NSDictionary<NSString *, NSString *> *headers,
                                                       NSError *error))completion {
    [self fetchClientInfoWithCompletion:^(NSError *error) {
        if (error) { completion(nil, error); return; }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSData *provisioningInfo = self.cachedProvisioningInfo;
        NSString *routingInfo = self.cachedRoutingInfo;
        if (provisioningInfo.length == 0 || routingInfo.length == 0) {
            provisioningInfo = [defaults dataForKey:RPVAnisetteProvisioningKey];
            routingInfo = [defaults stringForKey:RPVAnisetteRoutingInfoKey];
            self.cachedProvisioningInfo = provisioningInfo;
            self.cachedRoutingInfo = routingInfo;
        }
        if (!provisioningInfo || routingInfo.length == 0) {
            [self provisionAndFetchWithCompletion:completion];
            return;
        }

        [self requestHeadersWithProvisioningInfo:provisioningInfo routingInfo:routingInfo completion:^(NSDictionary *headers, NSError *error) {
            if (!error && headers) {
                completion(headers, nil);
                return;
            }

            // A GrandSlam identity and its resulting GS token are bound to the
            // ADI provisioning blob used to create them. Reprovisioning in the
            // middle of login, 2FA, or a Developer Services request makes an
            // otherwise valid session look expired. When pinned, let the
            // outer retry loop request another OTP from this same identity.
            if (self.identityPinned) {
                completion(nil, error ?: RPVAnisetteError(18, @"Could not refresh the pinned anisette identity"));
                return;
            }

            // Apple can invalidate provisioning. Keep the stable UUID, reset
            // only the ADI blob, and recover once automatically. This is safe
            // only before a fresh manual login has started GrandSlam.
            self.cachedProvisioningInfo = nil;
            self.cachedRoutingInfo = nil;
            [defaults removeObjectForKey:RPVAnisetteProvisioningKey];
            [defaults removeObjectForKey:RPVAnisetteRoutingInfoKey];
            [self provisionAndFetchWithCompletion:completion];
        }];
    }];
}

- (void)fetchAnisetteDataWithAttemptsRemaining:(NSUInteger)attempts
                                      completion:(void (^)(NSDictionary<NSString *, NSString *> *headers,
                                                           NSError *error))completion {
    [self fetchAnisetteDataOnceWithCompletion:^(NSDictionary<NSString *,NSString *> *headers, NSError *error) {
        if (!error || headers.count > 0 || attempts <= 1) {
            completion(headers, error);
            return;
        }

        // Short-lived disconnects are common while a WebSocket is upgrading
        // or the device is moving between network paths. Provisioning is
        // credential-free, so retry it without repeating Apple ID login.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self fetchAnisetteDataWithAttemptsRemaining:attempts - 1 completion:completion];
        });
    }];
}

- (void)fetchAnisetteDataWithCompletion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable headers,
                                                   NSError * _Nullable error))completion {
    [self fetchAnisetteDataWithAttemptsRemaining:3 completion:completion];
}

@end
