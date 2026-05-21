# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'

module RubyWorker
  # Fetcher clones the repo into a local cache directory when
  # the worker is dispatched in self-fetch mode (RepoSource on
  # the request). Returns the absolute path to the cached
  # checkout so the rest of the worker (Parser) can operate
  # against it exactly as if the bot had cloned it.
  #
  # # Cache layout
  #
  #   $REVUND_WORKER_CACHE_DIR/<sha256(url@ref)>/
  #
  # Default cache dir is /var/cache/revund-worker. The hash key
  # includes both URL and ref so two reviews targeting different
  # commits of the same repo share nothing — keeps tenant
  # blast-radius to one cache entry.
  #
  # # Token hygiene (security)
  #
  # The token is used at clone time only:
  #
  #   1. Compose the authenticated URL via x-access-token convention.
  #   2. Run `git clone --filter=blob:none --no-checkout <auth-url>`.
  #   3. Immediately rewrite the remote URL to the un-authenticated
  #      form via `git remote set-url`. After this step the on-disk
  #      .git/config carries no token.
  #   4. Fetch the requested ref and check it out.
  #
  # Errors and log messages NEVER include the URL with the embedded
  # token; the sanitizer strips it before raising.
  module Fetcher
    DEFAULT_CACHE_DIR = '/var/cache/revund-worker'
    DEFAULT_IDLE_TTL_SEC = 10 * 60 # 10 min

    @last_touched = {}

    # Resolve the local checkout for `src` (a Hash with :url,
    # :ref, :auth_token, :auth_user). Clones if cold, returns
    # the cached path if warm. Idempotent within the process
    # lifetime.
    def self.fetch_or_cache(src)
      url = src[:url].to_s
      ref = src[:ref].to_s
      raise 'fetcher: repo_source.url is required' if url.empty?
      raise 'fetcher: repo_source.ref is required' if ref.empty?

      cache_dir = ENV['REVUND_WORKER_CACHE_DIR'] || DEFAULT_CACHE_DIR
      FileUtils.mkdir_p(cache_dir)

      key = cache_key(url, ref)
      repo_dir = File.join(cache_dir, key)

      if File.directory?(File.join(repo_dir, '.git'))
        touch(repo_dir)
        return repo_dir
      end

      clean_url = url
      auth_url = inject_token(clean_url, src[:auth_token].to_s, src[:auth_user].to_s)
      FileUtils.mkdir_p(repo_dir)

      run('git', 'clone', '--filter=blob:none', '--no-checkout', auth_url, repo_dir)
      # Strip the token BEFORE doing anything else.
      run('git', '-C', repo_dir, 'remote', 'set-url', 'origin', clean_url)

      run('git', '-C', repo_dir, 'fetch', 'origin', ref)
      run('git', '-C', repo_dir, 'checkout', ref)

      touch(repo_dir)
      Thread.new { evict_idle(cache_dir) }

      repo_dir
    end

    class << self
      private

      def cache_key(url, ref)
        Digest::SHA256.hexdigest("#{url}@#{ref}")[0, 32]
      end

      def touch(dir)
        @last_touched[dir] = (Time.now.to_f * 1000).to_i
      end

      def evict_idle(cache_dir)
        ttl_sec = ENV['REVUND_WORKER_CACHE_TTL_SEC'].to_i
        ttl_ms = ttl_sec.positive? ? ttl_sec * 1000 : DEFAULT_IDLE_TTL_SEC * 1000
        cutoff = (Time.now.to_f * 1000).to_i - ttl_ms

        Dir.children(cache_dir).each do |e|
          full = File.join(cache_dir, e)
          t = @last_touched[full] || begin
            File.mtime(full).to_f * 1000
          rescue StandardError
            (Time.now.to_f * 1000).to_i
          end
          next if t > cutoff

          begin
            FileUtils.rm_rf(full)
            @last_touched.delete(full)
          rescue StandardError
            # Best-effort; stale entries get retried next sweep.
          end
        end
      end

      # Compose the authenticated clone URL by inserting a
      # basic-auth pair into the https URL. Username comes from
      # RepoSource.auth_user; when empty defaults to
      # "x-access-token" (GitHub). GitLab → "oauth2",
      # Bitbucket → "x-token-auth".
      def inject_token(clone_url, token, user = '')
        return clone_url if token.empty?
        return clone_url unless clone_url.start_with?('https://')

        u = user.empty? ? 'x-access-token' : user
        "https://#{u}:#{token}@" + clone_url.sub(%r{\Ahttps://}, '')
      end

      # Run a command, capture stderr, raise sanitized error on
      # non-zero exit. The raised message NEVER contains an
      # authenticated URL.
      def run(*cmd)
        _stdout, stderr, status = Open3.capture3(*cmd)
        return if status.success?

        sanitized = cmd.map { |a| looks_authenticated?(a) ? redact(a) : a }
        raise "fetcher: #{cmd.first} #{sanitized.drop(1).join(' ')} exited #{status.exitstatus}: #{redact(stderr)}"
      end

      def looks_authenticated?(arg)
        arg.is_a?(String) && arg =~ %r{\Ahttps?://[^/@]+:[^/@]+@}
      end

      def redact(str)
        str.gsub(%r{(https?://)[^/@\s]+:[^/@\s]+@}, '\1[redacted]@')
      end
    end
  end
end
