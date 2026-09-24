require "json"

module Scraper
  # The production fast path: shells out to curl-impersonate so the request
  # carries a real Chrome TLS + HTTP/2 fingerprint, which plain Ruby HTTP can't.
  #
  # It runs the `curl-impersonate` binary with `--impersonate <profile>` rather
  # than the curl_chrome* wrapper scripts: the wrappers hard-code a User-Agent
  # with -H, so replaying the solver's UA would send two User-Agent headers,
  # whereas --impersonate lets our -H replace the profile's UA in place and keep
  # Chrome's header order. The profile must match the browser that solved the
  # clearance (its TLS fingerprint and UA are bound together).
  #
  # Never raises on an HTTP status — a 403 is a Response for the detector.
  # Raises FetchFailed only when there is no response at all.
  class CurlImpersonateFetcher
    include Fetcher

    # Separates the body from the status + header trailer curl writes after it.
    META = "\n@@miniscrap-curl-meta@@\n".freeze
    MAX_REDIRECTS = 5
    # Headroom for curl to honour its own --max-time before we kill it.
    KILL_GRACE = 2

    def initialize(profile:, bin_dir:, timeout: 20, runner: Subprocess.method(:run))
      @profile = profile
      @binary = File.join(bin_dir, "curl-impersonate")
      @timeout = timeout
      @runner = runner
    end

    def fetch(url, ua: nil, cookies: {}, headers: {}, proxy: nil)
      result = @runner.call(command(url, ua:, cookies:, headers:, proxy:), timeout: @timeout + KILL_GRACE)
      raise FetchFailed, result.stderr.strip unless result.success?

      parse(result.stdout)
    rescue Subprocess::TimedOut => error
      raise FetchFailed, error.message
    rescue SystemCallError => error
      # The binary is missing or not executable — a setup problem, not a crash.
      raise FetchFailed, "cannot run #{@binary} (set CURL_IMPERSONATE_DIR): #{error.message}"
    end

    # Is the binary there and runnable? No request is made — for readiness
    # checks.
    def ready?
      File.executable?(@binary)
    end

    private

    def command(url, ua:, cookies:, headers:, proxy:)
      [
        @binary,
        "--impersonate", @profile.to_s,
        "--silent", "--show-error", "--compressed",
        "--location", "--max-redirs", MAX_REDIRECTS.to_s,
        "--max-time", @timeout.to_s,
        "--write-out", "#{META}%{response_code}#{META}%{header_json}",
        *header_args(ua, headers),
        *cookie_args(cookies),
        *(["--proxy", proxy] if proxy),
        url
      ]
    end

    # No UA means no override: the profile's own Chrome UA goes out.
    def header_args(ua, headers)
      headers = headers.merge("User-Agent" => ua) if ua
      headers.flat_map { |name, value| ["-H", "#{name}: #{value}"] }
    end

    def cookie_args(cookies)
      return [] if cookies.empty?

      ["--cookie", cookies.map { |name, value| "#{name}=#{value}" }.join("; ")]
    end

    # stdout is "<body><META><status><META><header json>" for the final
    # response after redirects. Split on bytes: the body's encoding is the
    # site's business, not ours.
    def parse(stdout)
      rest, _, header_json = stdout.b.rpartition(META.b)
      body, _, status = rest.rpartition(META.b)

      Response.new(
        status: status.to_i,
        headers: JSON.parse(header_json).transform_values { |values| Array(values).join(", ") },
        body: body.force_encoding(Encoding::UTF_8)
      )
    end
  end
end
