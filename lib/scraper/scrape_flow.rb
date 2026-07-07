module Scraper
  # The orchestrator. Site- and protection-agnostic: it talks only to injected
  # interfaces and *returns* a ScrapeResult (or raises) — it knows nothing about
  # Rails, JSON, or HTTP.
  #
  # This slice implements only the fast path: fetch -> parse -> return. Challenge
  # detection, the ClearanceStore, and the routed solve arrive in later slices
  # and slot in between the fetch and the parse without changing this contract.
  class ScrapeFlow
    def initialize(site:, fetcher:)
      @site = site
      @fetcher = fetcher
    end

    def run(path)
      started = monotonic_ms
      response = @fetcher.fetch(@site.url_for(path), ua: nil, cookies: {}, headers: {})
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
