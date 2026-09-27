require 'tmpdir'
require 'fileutils'
require 'json'

root = File.expand_path('../..', __dir__)
source = File.read(ARGV[0] || File.join(root, 'Shared/libProvision/Apple Services/RPVLoginImpl.m'))
logger = source[source.index('static NSString * const RPV2FADiagnosticsEnabledKey')...source.index('struct ccrng_state *ccDRBGGetRngState')]
start = source.index('- (void)makeRequestWithParameters:')
request_method = source[start..source.index(/^\}/, start)]
start = source.index('- (void)_makeRequestWithParameters:')
request_method += "\n" + source[start..source.index(/^\}/, start)]
%w[_newGrandSlamSessionWithTimeout _performGrandSlamRequest].each do |name|
  start = source.index(/^\- \([^\n]+\)#{name}\b/)
  request_method += "\n" + source[start..source.index(/^\}/, start)]
end
abort 'Missing production diagnostics' unless logger && request_method

Dir.mktmpdir('repro-diagnostic-test-') do |build|
  log_path = File.join(build, 'ReProvision-2FA-Debug.log')
  # Only the device-specific output path changes in the extracted logger.
  logger = logger.sub('/var/mobile/Documents/ReProvision-2FA-Debug.log', log_path)
  File.write(File.join(build, 'Logger.inc'), logger)
  File.write(File.join(build, 'Request.inc'), request_method)
  File.write(File.join(build, 'main.m'), <<~'OBJC')
    #import <Foundation/Foundation.h>
    #import <objc/runtime.h>
    #define RPVInternalLogin2FARequiredTrustedDeviceError 4010
    #define RPVInternalLogin2FARequiredSecondaryAuthError 4011
    #define RPVInternalLoginError 5000
    #define log_debug(...) ((void)0)
    #include "Logger.inc"
    @interface Probe : NSObject
    @end
    @implementation Probe
    - (NSDictionary *)defaultRequestHeaders { return @{}; }
    - (NSError *)createError:(NSString *)message :(int)code {
      return [NSError errorWithDomain:@"test.auth" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    }
    #include "Request.inc"
    @end
    @interface FakeApple : NSURLProtocol
    @end
    @implementation FakeApple
    + (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
    + (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
    - (void)startLoading {
      // Different status per request is selected by a harmless test header.
      BOOL fail = [[self.request valueForHTTPHeaderField:@"X-Test-Operation"] isEqualToString:@"apptokens"];
      NSData *data = fail ? [@"<html>SECRET_HTML_BODY</html>" dataUsingEncoding:NSUTF8StringEncoding]
        : [NSPropertyListSerialization dataWithPropertyList:@{@"Response":@{@"Status":@{@"ec":@0}, @"token":@"SECRET_RESPONSE_TOKEN"}}
            format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
      NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
        statusCode:fail ? 503 : 200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type":fail ? @"text/html" : @"text/x-xml-plist", @"Set-Cookie":@"SECRET_COOKIE", @"Retry-After":fail ? @"0" : @"30"}];
      [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
      [self.client URLProtocol:self didLoadData:data];
      [self.client URLProtocolDidFinishLoading:self];
    }
    - (void)stopLoading {}
    @end
    @interface NSURLSession (Mock)
    + (NSURLSession *)diagnosticTestSessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
    @end
    @implementation NSURLSession (Mock)
    + (NSURLSession *)diagnosticTestSessionWithConfiguration:(NSURLSessionConfiguration *)configuration {
      configuration.protocolClasses = @[FakeApple.class];
      return [self diagnosticTestSessionWithConfiguration:configuration];
    }
    @end
    @interface OperationProbe : Probe
    @property(nonatomic, copy) NSString *operation;
    @end
    @implementation OperationProbe
    - (NSDictionary *)defaultRequestHeaders {
      return @{@"X-Test-Operation": self.operation, @"Authorization":@"SECRET_HEADER_TOKEN", @"User-Agent":RPVGrandSlamUserAgent,
        @"X-MMe-Client-Info": [self.operation isEqualToString:@"apptokens"] ? @"<Mac SECRET_CHANGED>" : @"<Mac SECRET_CLIENT_INFO>"};
    }
    @end
    int main(void) { @autoreleasepool {
      Method real = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:));
      Method mock = class_getClassMethod(NSURLSession.class, @selector(diagnosticTestSessionWithConfiguration:));
      method_exchangeImplementations(real, mock);
      OperationProbe *probe = [OperationProbe new];
      for (NSString *operation in @[@"init", @"complete", @"apptokens"]) {
        probe.operation = operation;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block BOOL expectedResult = NO;
        NSDictionary *cpd = @{@"X-Apple-I-MD":@"SECRET_OTP", @"X-Apple-I-MD-M":NSNull.null,
          @"X-Apple-I-MD-RINFO": [operation isEqualToString:@"init"] ? @123 : @"SECRET_ROUTING",
          @"X-MMe-Client-Info":@"<Mac SECRET_CLIENT_INFO>", @"X-Mme-Device-Id":@"00000000-0000-0000-0000-000000000000",
          @"X-Apple-I-Client-Time":@"2026-09-06T00:00:00Z"};
        // NSNull is deliberately tested below, but is not a legal plist value.
        NSMutableDictionary *wireCPD = [cpd mutableCopy];
        [wireCPD removeObjectForKey:@"X-Apple-I-MD-M"];
        [probe _makeRequestWithParameters:@{@"o":operation, @"u":@"SECRET_APPLE_ID", @"password":@"SECRET_PASSWORD",
          @"code":@"SECRET_CODE", @"t":@"SECRET_REQUEST_TOKEN", @"cpd":wireCPD,
          @"checksum":[NSMutableData dataWithLength:32], @"app":@[@"com.apple.gs.xcode.auth"]}
          diagnosticContext:@{@"trace_id":@"test-trace", @"identity_source":@"native-authkit", @"initial_client_info":@"<Mac SECRET_CLIENT_INFO>"}
          completion:^(NSError *error, NSDictionary *response) {
            expectedResult = [operation isEqualToString:@"apptokens"]
              ? error != nil && [error.localizedDescription containsString:@"HTTP 503"]
              : error == nil && response != nil;
            dispatch_semaphore_signal(done);
          }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !expectedResult) return 1;
      }
      NSDictionary *malformed = RPVGrandSlamRequestDiagnostics(@{@"o":@"SECRET_UNKNOWN_OPERATION", @"cpd":@{@"X-Apple-I-MD":NSNull.null,
         @"X-Mme-Device-Id":@42, @"X-Apple-I-Client-Time":@[@"SECRET_BAD_DATE"]}}, @{}, nil);
      if (![malformed[@"operation"] isEqual:@"unknown"] || ![malformed[@"client_field_types"][@"X-Apple-I-MD"] isEqual:@"missing"] ||
          [malformed[@"client_time_parseable"] boolValue]) return 2;
      method_exchangeImplementations(real, mock);
      return 0;
    } }
  OBJC
  app = File.join(build, 'Probe.app/Contents')
  FileUtils.mkdir_p(File.join(app, 'MacOS'))
  binary = File.join(app, 'MacOS/Probe')
  abort 'Compile failed' unless system('xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks', '-Wno-incompatible-pointer-types', '-I', build,
                                      File.join(build, 'main.m'), '-framework', 'Foundation', '-o', binary)
  [false, true].each do |enabled|
    File.write(File.join(app, 'Info.plist'), <<~XML)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>Probe</string>
      <key>CFBundleIdentifier</key><string>test.repro.diagnostics</string>
      <key>RPV2FADiagnosticsEnabled</key><#{enabled}/>
      </dict></plist>
    XML
    abort 'Mock login failed' unless system(binary)
    if !enabled
      abort 'Logging was not opt-in' if File.exist?(log_path)
      puts 'PASS diagnostics disabled: no file written'
      next
    end
    text = File.read(log_path)
    records = text.lines.map { |line| JSON.parse(line) }
    responses = records.select { |r| r['event'] == 'grandslam.response' }
    abort 'Wrong stages/statuses' unless responses.map { |r| [r['operation'], r['http_status']] } == [['init', 200], ['complete', 200], ['apptokens', 503]]
    abort 'Raw sensitive test value leaked' if text.include?('SECRET_')
    request_records = records.select { |r| r['event'] == 'grandslam.request' }
    abort 'Missing requests' unless request_records.size == 3
    abort 'Missing field not reported' unless request_records.all? { |r| r['client_field_types']['X-Apple-I-MD-M'] == 'missing' }
    abort 'Wrong field type' unless request_records.map { |r| r['client_field_types']['X-Apple-I-MD-RINFO'] } == %w[number string string]
    abort 'Identity drift not reported' unless request_records.map { |r| r['client_description_matches_login_start'] } == [true, true, false]
    abort 'Wrong clock/checksum/ID metadata' unless request_records.all? { |r| r['checksum_bytes'] == 32 && r['device_id_format'] == 'uuid' && r['client_time_parseable'] }
    abort 'Request/response correlation failed' unless request_records.map { |r| r['request_id'] } == responses.map { |r| r['request_id'] }
    attempts = records.select { |r| r['event'] == 'grandslam.transport_attempt' }
    abort 'Transport diagnostics missing' unless attempts.size == 5 && attempts.all? { |r| r['fresh_session'] && r['modern_user_agent'] && r['transport_revision'] == 2 }
    abort 'Wrong attempt numbers' unless attempts.map { |r| r['attempt'] } == [1, 1, 1, 2, 3]
    abort 'Attempt correlation failed' unless attempts.map { |r| r['request_id'] }.uniq == responses.map { |r| r['request_id'] }
    retries = records.select { |r| r['event'] == 'grandslam.retry' }
    abort 'Retry events missing' unless retries.map { |r| r['retry_delay_seconds'] } == [1, 2] && retries.all? { |r| r['request_id'] == responses.last['request_id'] }
    abort 'Retry-After not captured' unless responses.map { |r| r['retry_after_seconds'] } == [30, 30, 0]
    abort 'Unexpected log fields' unless records.all? { |r| (r.keys - %w[event time_unix_ms operation data_bytes http_status mime_type parsed_response apple_code_present apple_code diagnostic_schema request_id trace_id identity_source request_field_types client_field_types client_description_present client_description_is_mac body_client_description_present body_header_client_description_match requested_xcode_token client_description_matches_login_start device_id_format client_time_parseable client_clock_skew_seconds checksum_bytes cookie_handling_enabled existing_cookie_count duration_ms response_url_matches_request response_https set_cookie_present www_authenticate_present retry_after_present retry_after_seconds outer_auth_mode response_field_types server_family via_header_present attempt fresh_session transport_revision modern_user_agent transport_error_code retry_delay_seconds client_info_header_client client_info_body_client user_agent_client]).empty? }
    abort 'Client roles must remain categorical' unless request_records.all? { |r| %w[client_info_header_client client_info_body_client user_agent_client].all? { |key| %w[missing xcode akd other].include?(r[key]) } }
    puts 'PASS diagnostics enabled: init 200, complete 200, apptokens 503 recorded without a 2FA prompt'
    puts 'PASS fake passwords, codes, Apple IDs, headers, cookies, tokens, and HTML body excluded'
    puts 'PASS log JSON and allowed field list'
    puts 'PASS missing fields, wrong types, identity drift, checksum/clock metadata, request correlation, Retry-After'
    puts 'PASS malformed diagnostic input is handled without copying unknown values'
    puts 'PASS retry events, attempt numbering, isolated-session flags, and correlation remain sanitized'
  end
end
