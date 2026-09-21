require "json"
require "net/http"

module Scraper
  # The slow path: asks a running FlareSolverr service (a stealth headless
  # Chromium, run as a Docker container) to load the URL, execute Cloudflare's
  # challenge JS, and hand back what the browser ended up with — its cookies
  # (the prize: cf_clearance) and the exact User-Agent it used, which the
  # clearance is bound to.
  #
  # It only turns "a URL behind Cloudflare" into a Clearance: no parsing, no
  # detection, no caching. Failures are raised, never returned as an empty
  # clearance — SolveTimeout past the deadline, SolveFailed for anything else
  # (service down, error reply, or a "solved" page without cf_clearance).
  #
  # Version coupling: FlareSolverr's bundled Chromium sets the UA we replay,
  # while the Site's curl-impersonate profile sets the TLS fingerprint. Keep
  # them close (FlareSolverr 3.5.2 ships Chrome 152; nissei uses chrome146).
  class FlareSolverrSolver
    include Solver

    CLEARANCE_COOKIE = "cf_clearance".freeze
    # Headroom for FlareSolverr to report its own timeout before we give up.
    READ_GRACE = 10

    # timeout: the solve deadline in seconds. ttl: the most we trust a
    # clearance for — the cookie's own expiry is far longer than Cloudflare
    # honours it; earlier death is caught reactively by a fresh 403.
    def initialize(base_url:, timeout: 60, ttl: 1800, clock: -> { Time.now })
      @endpoint = URI.join(base_url, "/v1")
      @timeout = timeout
      @ttl = ttl
      @clock = clock
    end

    def solve(url, _challenge)
      solution = request_solve(url)
      clearance_cookie = solution.fetch("cookies", []).find { |cookie| cookie["name"] == CLEARANCE_COOKIE }
      raise SolveFailed, "FlareSolverr returned no #{CLEARANCE_COOKIE} cookie" unless clearance_cookie

      Clearance.new(
        cookies: solution["cookies"].to_h { |cookie| [cookie["name"], cookie["value"]] },
        headers: {},
        ua: solution.fetch("userAgent"),
        expires_at: expires_at(clearance_cookie)
      )
    end

    private

    def request_solve(url)
      body = JSON.parse(post(cmd: "request.get", url: url, maxTimeout: @timeout * 1000).body)
      return body["solution"] if body["status"] == "ok" && body["solution"]

      message = "FlareSolverr: #{body["message"]}"
      raise SolveTimeout, message if body["message"].to_s.match?(/timeout/i)

      raise SolveFailed, message
    rescue Net::ReadTimeout
      raise SolveTimeout, "FlareSolverr did not answer within #{@timeout + READ_GRACE}s"
    rescue JSON::ParserError, SystemCallError, SocketError, IOError, Net::OpenTimeout => error
      raise SolveFailed, "FlareSolverr unavailable: #{error.message}"
    end

    def post(payload)
      Net::HTTP.start(@endpoint.host, @endpoint.port, open_timeout: 5, read_timeout: @timeout + READ_GRACE) do |http|
        http.post(@endpoint.path, payload.to_json, "Content-Type" => "application/json")
      end
    end

    def expires_at(cookie)
      cap = @clock.call + @ttl
      expiry = cookie["expiry"] || cookie["expires"]
      expiry.to_i.positive? ? [Time.at(expiry.to_i), cap].min : cap
    end
  end
end
