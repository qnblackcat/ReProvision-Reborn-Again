#!/usr/bin/env ruby
# Compile the real Developer Services implementation with a fake transport.
# Extract the Foundation-only 2FA parser methods verbatim so the SRP/AuthKit
# dependencies are not required on macOS. No Apple account or network is used.
require 'tmpdir'
require 'open3'

root = File.expand_path(ARGV[0] || '../..', __dir__)
services = File.join(root, 'Shared/libProvision/Apple Services')
source = File.read(File.join(services, 'RPVLoginImpl.m'))
methods = %w[_twoFactorDictionaryFromData _twoFactorResponseContainers
             _twoFactorErrorCodeFromResponseDictionary
             _twoFactorErrorMessageFromResponseDictionary _twoFactorServerErrorForData]
extracted = methods.map do |name|
  start = source.index(/^\- \([^\n]+\)#{name}:/)
  raise "Missing production method: #{name}" unless start
  ending = source.index(/^\}/, start)
  raise "Missing method end: #{name}" unless ending
  source[start..ending]
end.join("\n\n")

Dir.mktmpdir('repro-auth-tests-') do |build|
  File.write(File.join(build, 'ParserMethods.inc'), extracted)
  command = ['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks',
             '-Wno-incompatible-pointer-types', '-Wno-objc-method-access',
             '-I', services, '-I', File.join(__dir__, 'Stubs'), '-I', build,
             File.join(__dir__, 'AuthRegressionTests.m'),
             File.join(services, 'EEAppleServices.m'),
             File.join(services, 'NSData+GZIP.m'),
             '-framework', 'Foundation', '-o', File.join(build, 'auth-tests')]
  abort 'Authentication test compilation failed' unless system(*command)
  exit(system(File.join(build, 'auth-tests')) ? 0 : 1)
end
