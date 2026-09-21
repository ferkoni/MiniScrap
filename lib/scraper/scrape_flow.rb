module Scraper
  # The orchestrator. Site- and protection-agnostic: it talks only to injected
  # interfaces and *returns* a ScrapeResult (or raises) — it knows nothing about
  # Rails, JSON, or HTTP.
  #
  # fast fetch -> detect -> (on a challenge) resolve a clearance through the
  # shared ClearanceStore -> bounded retry -> parse. The fast path always goes
  # first, presenting a cached clearance when the store holds one; a challenge
  # means that clearance (if any) is dead, so it is dropped and a fresh one is
  # resolved, up to `max_retries` times. A cleared page that parses to zero
  # products comes back flagged degraded: "zero_results".
  class ScrapeFlow
    ZERO_RESULTS = "zero_results".freeze

    def initialize(site:, fetcher:, detector:, store:, max_retries: 1)
      @site = site
      @fetcher = fetcher
      @detector = detector
      @store = store
      @max_retries = max_retries
    end

    def run(path)
      started = monotonic_ms
      url = @site.url_for(path)
      key = ClearanceKey.new(site_id: @site.id)
      clearance = @store.peek(key, refresh_url: url) # may also refresh ahead, in the background
      browser_used = false
      retries = 0

      response = fetch(url, clearance)
      while (challenge = @detector.detect(response))
        # Whatever we presented did not clear — expired early or never worked —
        # so drop it before this request or the next one reuses it.
        @store.invalidate(key, clearance) if clearance
        raise RetryBudgetExhausted if retries >= @max_retries

        retries += 1
        clearance = @store.clearance(key, url, challenge)
        browser_used = true
        response = fetch(url, clearance)
      end

      results = @site.parser.parse(response.body)
      ScrapeResult.new(
        site: @site.id,
        results: results,
        browser_used: browser_used,
        latency_ms: (monotonic_ms - started).round,
        # A cleared page with nothing on it is a structural anomaly (most
        # likely a layout the parser no longer understands), not a challenge:
        # flag it rather than return a silent empty success.
        degraded: (ZERO_RESULTS if results.empty?)
      )
    end

    private

    # Replays the clearance's cookies, headers, and UA together — they are bound
    # to each other — or fetches bare when there is none.
    def fetch(url, clearance)
      @fetcher.fetch(
        url,
        ua: clearance&.ua,
        cookies: clearance&.cookies || {},
        headers: clearance&.headers || {}
      )
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
