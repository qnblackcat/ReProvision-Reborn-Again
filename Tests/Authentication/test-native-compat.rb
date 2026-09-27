require 'tmpdir'
require 'fileutils'
root = File.expand_path('../..', __dir__)
source = File.read(ARGV[0] || File.join(root, 'Shared/libProvision/Apple Services/RPVLoginImpl.m'))
helpers = source[source.index('static NSString * const RPV2FADiagnosticsEnabledKey')...source.index('struct ccrng_state *ccDRBGGetRngState')]
methods = %w[setClientInfoOverride setAnisetteDataOverride defaultRequestHeaders _twoFactorHeadersWithUserIdentity _nativeAnisetteContextRequest _anisetteData _grandSlamClientData].map do |name|
  start = source.index(/^\- \([^\n]+\)#{name}\b/)
  abort "Missing method #{name}" unless start
  source[start..source.index(/^\}/, start)]
end.join("\n\n")
Dir.mktmpdir('repro-native-compat-') do |build|
  log = File.join(build, 'diagnostics.log')
  File.write(File.join(build, 'Helpers.inc'), helpers.sub('/var/mobile/Documents/ReProvision-2FA-Debug.log', log))
  File.write(File.join(build, 'Methods.inc'), methods)
  File.write(File.join(build, 'main.m'), <<~'OBJC')
    #import <Foundation/Foundation.h>
    #include <errno.h>
    #include <stdlib.h>
    #define TARGET_OS_SIMULATOR 0
    #define RPVInternalLogin2FARequiredTrustedDeviceError 4010
    #define RPVInternalLogin2FARequiredSecondaryAuthError 4011
    #include "Helpers.inc"
    static NSURLRequest *lastRequest;
    static NSUInteger nativeCalls;
    static BOOL omitLocalUser;
    @interface AKAppleIDSession : NSObject
    - (instancetype)initWithIdentifier:(NSString *)identifier;
    - (NSDictionary *)appleIDHeadersForRequest:(NSURLRequest *)request;
    @end
    @implementation AKAppleIDSession
    - (instancetype)initWithIdentifier:(NSString *)identifier { return [super init]; }
    - (NSDictionary *)appleIDHeadersForRequest:(NSURLRequest *)request {
      lastRequest = [request copy]; nativeCalls++;
      NSMutableDictionary *headers = [@{@"X-Apple-I-MD":@"SECRET_OTP", @"X-Apple-I-MD-M":@"SECRET_MACHINE",
        @"X-Apple-I-MD-RINFO":@"17106176"} mutableCopy];
      if (request && !omitLocalUser) headers[@"X-Apple-I-MD-LU"] = @"SECRET_NATIVE_LOCAL_USER";
      return headers;
    }
    @end
    @interface Probe : NSObject
    @property(nonatomic, strong) NSDictionary *anisetteDataOverride;
    @property(nonatomic, copy) NSString *clientInfoOverride;
    @end
    @implementation Probe
    @synthesize clientInfoOverride = _clientInfoOverride;
    @synthesize anisetteDataOverride = _anisetteDataOverride;
    - (void)_ensureAuthKitAvailable {}
    - (NSDictionary *)_deviceData {
      return self.anisetteDataOverride.count ? @{} : @{@"X-Mme-Device-Id":@"SECRET_NATIVE_DEVICE"};
    }
    #include "Methods.inc"
    @end
    static int failures;
    static void Check(BOOL condition, NSString *label) {
      printf("%s %s\n", condition ? "PASS" : "FAIL", label.UTF8String);
      if (!condition) failures++;
    }
    int main(void) { @autoreleasepool {
      BOOL enabled = RPVNativeAuthCompatibilityEnabled();
      Probe *probe = [Probe new]; probe.clientInfoOverride = @"<Mac SECRET_CLIENT>";
      NSDictionary *headers = [probe _anisetteData];
      Check((lastRequest != nil) == enabled, @"compatibility gate controls native request context");
      if (enabled) {
        Check([lastRequest.HTTPMethod isEqual:@"POST"] &&
          [lastRequest.URL.absoluteString isEqual:@"https://developerservices2.apple.com/services/QH65B2/viewDeveloper.action?clientId=XABBG36SBA"], @"native context has correct URL/method");
        Check(lastRequest.HTTPBody.length == 0 && lastRequest.allHTTPHeaderFields.count == 0, @"native context contains no login credentials");
        Check([headers[@"X-Apple-I-MD-LU"] isEqual:@"SECRET_NATIVE_LOCAL_USER"], @"AuthKit local-user value preserved when supplied");
      }
      Check([headers[@"X-Apple-I-MD-RINFO"] isKindOfClass:NSString.class], @"HTTP-header representation remains string");
      NSDictionary *body = [probe _grandSlamClientData];
      Check([body[@"X-Apple-I-MD-RINFO"] isKindOfClass:enabled ? NSNumber.class : NSString.class], @"plist routing-info type follows compatibility gate");
      Check([body[@"X-Apple-I-MD-RINFO"] longLongValue] == 17106176, @"routing-info value preserved");
      Check([body[@"X-Apple-I-MD-M"] isEqual:@"SECRET_MACHINE"] && [body[@"X-Mme-Device-Id"] isEqual:@"SECRET_NATIVE_DEVICE"], @"machine and device identity preserved");
      omitLocalUser = YES;
      body = [probe _grandSlamClientData];
      Check(body[@"X-Apple-I-MD-LU"] == nil, @"missing local-user ID is never fabricated");
      NSUInteger before = nativeCalls;
      NSDictionary *remote = @{@"X-Apple-I-MD-RINFO":@"42", @"X-Mme-Device-Id":@"SECRET_REMOTE_DEVICE", @"X-Apple-I-MD-LU":@"SECRET_REMOTE_USER"};
      probe.anisetteDataOverride = remote;
      body = [probe _grandSlamClientData];
      Check(nativeCalls == before, @"remote override bypasses native AuthKit");
      Check([remote[@"X-Apple-I-MD-RINFO"] isKindOfClass:NSString.class], @"source headers not mutated");
      Check([body[@"X-Mme-Device-Id"] isEqual:@"SECRET_REMOTE_DEVICE"] && [body[@"X-Apple-I-MD-LU"] isEqual:@"SECRET_REMOTE_USER"], @"remote identity preserved");
      Check([RPVRoutingInfoNumber(@"17106176") isEqual:@17106176] && [RPVRoutingInfoNumber(@"0") isEqual:@0], @"decimal strings parsed correctly");
      Check([RPVRoutingInfoNumber(@42) isEqual:@42], @"existing number retained");
      for (id bad in @[@"", @"invalid", @"12x", @"-1", @"1.5", @" 42", @"9223372036854775808", @"99999999999999999999999999", NSNull.null, @[]]) {
        Check(RPVRoutingInfoNumber(bad) == nil, @"invalid/overflow input rejected, not converted to zero");
      }
      probe.anisetteDataOverride = @{@"X-Apple-I-MD-RINFO":@"invalid"};
      Check([[probe _grandSlamClientData][@"X-Apple-I-MD-RINFO"] isEqual:@"invalid"], @"malformed input remains visible in diagnostics rather than invented");
      NSString *originalClient = @"<MacBookPro13,2> <macOS;13.1;SECRET_BUILD> <com.apple.AuthKit/1 (com.apple.dt.Xcode/3594.4.19)>";
      NSString *expectedClient = @"<MacBookPro13,2> <macOS;13.1;SECRET_BUILD> <com.apple.AuthKit/1 (com.apple.akd/1.0)>";
      NSMutableDictionary *provider = [@{@"X-MMe-Client-Info":originalClient, @"X-Apple-I-MD":@"SECRET_OTP",
        @"X-Apple-I-MD-M":@"SECRET_MACHINE", @"X-Apple-I-MD-LU":@"SECRET_LOCAL_USER", @"X-Mme-Device-Id":@"SECRET_UUID",
        @"X-Apple-I-SRL-NO":@"SECRET_SERIAL", @"X-Apple-I-MD-RINFO":@"42"} mutableCopy];
      probe.anisetteDataOverride = provider;
      probe.clientInfoOverride = originalClient;
      Check([probe.clientInfoOverride isEqual:expectedClient], @"Xcode client token replaced without changing hardware or OS");
      Check([provider[@"X-MMe-Client-Info"] isEqual:originalClient], @"original provider dictionary is not mutated");
      for (NSString *key in provider) {
        if (![key isEqual:@"X-MMe-Client-Info"])
          Check([probe.anisetteDataOverride[key] isEqual:provider[key]], @"cryptographic/provider metadata preserved");
      }
      provider[@"X-Apple-I-MD"] = @"SECRET_CHANGED_OTP";
      Check([probe.anisetteDataOverride[@"X-Apple-I-MD"] isEqual:@"SECRET_OTP"], @"provider mutation cannot change the captured identity");
      Check([[probe _anisetteData][@"X-MMe-Client-Info"] isEqual:expectedClient], @"lookup/anisette headers use normalized client");
      Check([[probe defaultRequestHeaders][@"X-MMe-Client-Info"] isEqual:expectedClient], @"GrandSlam header uses normalized client");
      NSDictionary *normalizedBody = [probe _grandSlamClientData];
      Check([normalizedBody[@"X-MMe-Client-Info"] isEqual:expectedClient], @"GrandSlam plist matches normalized header");
      Check([[probe _twoFactorHeadersWithUserIdentity:@"SECRET_DSID|SECRET_ID" idmsToken:@"SECRET_TOKEN"][@"X-MMe-Client-Info"] isEqual:expectedClient], @"2FA headers use same normalized client");
      NSDictionary *summary = RPVGrandSlamRequestDiagnostics(@{@"o":@"init", @"cpd":normalizedBody}, [probe defaultRequestHeaders], nil);
      Check([summary[@"client_info_header_client"] isEqual:@"akd"] && [summary[@"client_info_body_client"] isEqual:@"akd"], @"diagnostics report header/body role without raw identity");
      Check([summary[@"user_agent_client"] isEqual:@"xcode"], @"User-Agent and client-info are classified separately");
      Check([RPVCompatibleClientInfo(expectedClient) isEqual:expectedClient], @"already-working akd client remains byte-identical");
      Check([RPVCompatibleClientInfo(@"<Mac> <OS> <Kit (com.apple.dt.Xcode/26.0)>") isEqual:@"<Mac> <OS> <Kit (com.apple.akd/1.0)>"], @"newer Xcode version normalized");
      Check([RPVCompatibleClientInfo(@"<Mac> <OS> <Kit (com.apple.dt.Xcode/9999.9)>") isEqual:@"<Mac> <OS> <Kit (com.apple.akd/1.0)>"], @"normalization does not depend on a specific Xcode version");
      Check([RPVCompatibleClientInfo(@"<Mac> <OS> <Kit (com.example.client/1)>") isEqual:@"<Mac> <OS> <Kit (com.example.client/1)>"], @"unrelated client is not rewritten");
      Check([RPVCompatibleClientInfo(@"com.apple.dt.Xcode/26.0 malformed") isEqual:@"com.apple.dt.Xcode/26.0 malformed"], @"malformed token outside client slot is not guessed");
      Check(RPVCompatibleClientInfo(NSNull.null) == nil && [RPVDiagnosticClientKind(NSNull.null) isEqual:@"missing"], @"invalid input handled safely");
      probe.anisetteDataOverride = nil;
      probe.clientInfoOverride = expectedClient;
      Check([[probe _grandSlamClientData][@"X-MMe-Client-Info"] isEqual:expectedClient], @"native fallback keeps working akd identity");
      return failures ? 1 : 0;
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
      <key>CFBundleIdentifier</key><string>test.repro.native</string>
      <key>RPV2FADiagnosticsEnabled</key><true/>
      <key>RPVNativeAuthCompatibilityTestEnabled</key><#{enabled}/>
      </dict></plist>
    XML
    puts "Compatibility enabled: #{enabled}"
    abort 'Native compatibility tests failed' unless system(binary)
  end
  abort 'Sensitive data logged' if File.read(log).include?('SECRET_')
  puts 'PASS native diagnostics exclude synthetic secret values'
end
