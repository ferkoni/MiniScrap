module Scraper
  # A Solver that returns a fixed Clearance instead of driving a browser — no
  # Docker, no network. The spec injection seam: it counts its `calls` so specs
  # can assert how many solves happened. Production routes :cloudflare_js to
  # FlareSolverrSolver.
  class StubSolver
    include Solver

    UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36".freeze
    COOKIES = { "cf_clearance" => "stub-clearance" }.freeze

    attr_reader :calls

    def initialize(clock: -> { Time.now }, ttl: 1800)
      @clock = clock
      @ttl = ttl
      @calls = 0
    end

    def solve(_url, _challenge)
      @calls += 1
      Clearance.new(cookies: COOKIES, headers: {}, ua: UA, expires_at: @clock.call + @ttl)
    end
  end
end
