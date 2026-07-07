module Scraper
  # The orchestrator. Site- and protection-agnostic: it talks only to injected
  # interfaces and *returns* a ScrapeResult (or raises) — it knows nothing about
  # Rails, JSON, or HTTP.
  #
  # This slice runs fetch -> detect -> parse -> return. A detected challenge has
  # no solver wired yet, so it is raised as UnsupportedChallenge; the reactive
  # solve + retry and the ClearanceStore arrive in later slices and slot in
  # between detection and the parse without changing this contract.
  class ScrapeFlow
    def initialize(site:, fetcher:, detector:)
      @site = site
      @fetcher = fetcher
      @detector = detector
    end

    def run(path)
      started = monotonic_ms
      response = @fetcher.fetch(@site.url_for(path), ua: nil, cookies: {}, headers: {})

      if (challenge = @detector.detect(response))
        # No solver is registered in this slice, so any detected challenge is
        # unsupported; slice #3 routes it through a SolverRegistry instead.
        raise UnsupportedChallenge, challenge.kind
      end

      results = @site.parser.parse(response.body)

      ScrapeResult.new(
        site: @site.id,
        results: results,
        browser_used: false,
        latency_ms: (monotonic_ms - started).round,
        degraded: nil # zero-products structural-anomaly detection arrives in slice #7
      )
    end

    private

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
