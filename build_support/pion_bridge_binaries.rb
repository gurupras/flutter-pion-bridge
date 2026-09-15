# Release binaries for the CocoaPods builds (iOS, macOS).
#
# Same contract as pion_bridge_binaries.cmake: a podspec uses the files that
# scripts/build_<platform>.sh leaves in the plugin source tree when they exist
# (local development); otherwise it calls PionBridgeBinaries.download, which
# fetches the release archive matching pubspec.yaml's version from GitHub
# Releases, checks it against the release's SHA256SUMS, and extracts it inside
# the pod directory.
#
# This runs while CocoaPods evaluates the podspec (pod install): vendored
# frameworks and resources must be on disk before the Pods project is
# generated, and Flutter plugins are :path pods, so prepare_command never runs.
#
# PION_BRIDGE_BINARIES_BASE_URL (environment) replaces the release download URL,
# e.g. a mirror, or file:///path/to/dist to try archives before publishing them.
# When it is set, podspecs download even if local outputs exist. The extracted
# copy is cached per version in <pod>/Downloaded (delete it to refetch).

require 'digest'
require 'fileutils'
require 'net/http'
require 'tmpdir'
require 'uri'

module PionBridgeBinaries
  RELEASES = 'https://github.com/gurupras/flutter-pion-bridge/releases/download'.freeze

  # Returns the archive's directory relative to pod_dir, for podspec paths.
  def self.download(pod_dir, platform)
    version = File.read(File.join(pod_dir, '..', 'pubspec.yaml'))[/^version:[ \t]*([^+\s]+)/, 1]
    raise 'pion_bridge: no version in pubspec.yaml' unless version

    relative = File.join('Downloaded', version)
    dest = File.join(pod_dir, relative)
    return relative if File.exist?(File.join(dest, '.complete'))

    base = ENV['PION_BRIDGE_BINARIES_BASE_URL'] || "#{RELEASES}/v#{version}"
    name = "pionbridge-#{version}-#{platform}.tar.gz"
    hint = 'Build the binaries locally (scripts/build_*.sh) or set PION_BRIDGE_BINARIES_BASE_URL.'

    expected = fetch("#{base}/SHA256SUMS", hint).lines.map(&:split)
                                                .find { |_, file| file&.delete_prefix('*') == name }&.first
    raise "pion_bridge: #{name} is not listed in #{base}/SHA256SUMS\n#{hint}" unless expected

    Pod::UI.puts "pion_bridge: downloading #{base}/#{name}" if defined?(Pod::UI)
    data = fetch("#{base}/#{name}", hint)
    actual = Digest::SHA256.hexdigest(data)
    unless actual.casecmp?(expected)
      raise "pion_bridge: #{name} SHA-256 mismatch: expected #{expected}, got #{actual}"
    end

    Dir.mktmpdir do |tmp|
      archive = File.join(tmp, name)
      File.binwrite(archive, data)
      staging = File.join(tmp, 'extracted')
      FileUtils.mkdir_p(staging)
      system('tar', '-xzf', archive, '-C', staging, exception: true)
      File.write(File.join(staging, '.complete'), '')
      FileUtils.rm_rf(dest)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.mv(staging, dest)
    end
    relative
  end

  def self.fetch(url, hint, redirects = 5)
    uri = URI(url)
    return File.binread(URI.decode_www_form_component(uri.path)) if uri.scheme == 'file'

    response = Net::HTTP.get_response(uri)
    case response
    when Net::HTTPSuccess
      response.body
    when Net::HTTPRedirection
      raise "pion_bridge: too many redirects fetching #{url}" if redirects.zero?

      fetch(URI.join(url, response['location']).to_s, hint, redirects - 1)
    else
      raise "pion_bridge: downloading #{url} failed: HTTP #{response.code}\n#{hint}"
    end
  rescue SystemCallError, IOError, SocketError => e
    raise "pion_bridge: downloading #{url} failed: #{e.message}\n#{hint}"
  end
end
