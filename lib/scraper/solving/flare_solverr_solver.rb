require "json"
require "net/http"

module Scraper
  # The slow path: asks a running FlareSolverr service (a stealth headless
  # Chromium, run as a Docker container) to load the URL, execute the
  # challenge JS, and hand back what the browser ended up with — its cookies
  # (the prize: the clearance cookie) and the exact User-Agent it used, which
  # the clearance is bound to.
  #
  # One instance per protection: `clearance_cookie` names the cookie that
  # proves a solve (Cloudflare: cf_clearance; AWS WAF: aws-waf-token).
  # FlareSolverr only recognises Cloudflare's challenge; on any other it
  # returns as soon as the page loads, mid-challenge. `wait` keeps the browser
  # running that many seconds longer (FlareSolverr's waitInSeconds), so the
  # challenge script can finish and set its cookie.
  #
  # It only turns "a URL behind a JS challenge" into a Clearance: no parsing,
  # no detection, no caching. Failures are raised, never returned as an empty
  # clearance — SolveTimeout past the deadline, SolveFailed for anything else
  # (service down, error reply, or a "solved" page without the clearance
  # cookie).
  #
  # Version coupling: FlareSolverr's bundled Chromium sets the UA we replay,
  # while the Site's curl-impersonate profile sets the TLS fingerprint. Keep
  # them close (FlareSolverr 3.5.2 ships Chrome 152; nissei uses chrome146).
  class FlareSolverrSolver
    include Solver

    # Headroom for FlareSolverr to report its own timeout before we give up.
    READ_GRACE = 10

    # timeout: the solve deadline in seconds. ttl: the most we trust a
    # clearance for — the cookie's own expiry is far longer than the site
    # honours it; earlier death is caught reactively by a fresh challenge.
    def initialize(base_url:, clearance_cookie: "cf_clearance", wait: nil, timeout: 60, ttl: 1800, clock: -> { Time.now })
      @root = URI.join(base_url, "/")
      @endpoint = URI.join(base_url, "/v1")
      @clearance_cookie = clearance_cookie
      @wait = wait
      @timeout = timeout
      @ttl = ttl
      @clock = clock
    end

    def solve(url, _challenge, proxy: nil)
      solution = request_solve(url, proxy)
      clearance_cookie = solution.fetch("cookies", []).find { |cookie| cookie["name"] == @clearance_cookie }
      raise SolveFailed, "FlareSolverr returned no #{@clearance_cookie} cookie" unless clearance_cookie

      Clearance.new(
        cookies: solution["cookies"].to_h { |cookie| [cookie["name"], cookie["value"]] },
        headers: {},
        ua: solution.fetch("userAgent"),
        expires_at: expires_at(clearance_cookie)
      )
    end

    # Is the service up at all? A cheap GET of FlareSolverr's root, never a
    # solve — for readiness checks.
    def ready?
      Net::HTTP.start(@root.host, @root.port, open_timeout: 2, read_timeout: 2) do |http|
        http.get(@root.path).is_a?(Net::HTTPSuccess)
      end
    rescue StandardError
      false
    end

    private

    def request_solve(url, proxy)
      payload = { cmd: "request.get", url: url, maxTimeout: @timeout * 1000 }
      payload[:waitInSeconds] = @wait if @wait
      payload[:proxy] = proxy_option(proxy) if proxy
      body = JSON.parse(post(payload).body)
      return body["solution"] if body["status"] == "ok" && body["solution"]

      message = "FlareSolverr: #{body["message"]}"
      raise SolveTimeout, message if body["message"].to_s.match?(/timeout/i)

      raise SolveFailed, message
    rescue Net::ReadTimeout
      raise SolveTimeout, "FlareSolverr did not answer within #{read_timeout}s"
    rescue JSON::ParserError, SystemCallError, SocketError, IOError, Net::OpenTimeout => error
      raise SolveFailed, "FlareSolverr unavailable: #{error.message}"
    end

    def post(payload)
      Net::HTTP.start(@endpoint.host, @endpoint.port, open_timeout: 5, read_timeout: read_timeout) do |http|
        http.post(@endpoint.path, payload.to_json, "Content-Type" => "application/json")
      end
    end

    # The wait happens inside FlareSolverr's call, so the deadline covers it.
    def read_timeout
      @timeout + @wait.to_i + READ_GRACE
    end

    # FlareSolverr takes the proxy URL and its credentials as separate fields.
    def proxy_option(proxy)
      uri = URI(proxy)
      option = { url: "#{uri.scheme}://#{uri.host}:#{uri.port}" }
      option[:username] = URI.decode_www_form_component(uri.user) if uri.user
      option[:password] = URI.decode_www_form_component(uri.password) if uri.password
      option
    end

    def expires_at(cookie)
      cap = @clock.call + @ttl
      expiry = cookie["expiry"] || cookie["expires"]
      expiry.to_i.positive? ? [Time.at(expiry.to_i), cap].min : cap
    end
  end
end
