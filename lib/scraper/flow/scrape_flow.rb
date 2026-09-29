module Scraper
  # The orchestrator. Site- and protection-agnostic: it talks only to injected
  # interfaces and *returns* a ScrapeResult (or raises) — it knows nothing about
  # Rails, JSON, or HTTP.
  #
  # fast fetch -> detect -> (on a challenge) resolve a clearance through the
  # shared ClearanceStore -> bounded retry -> parse. The fast path always goes
  # first, presenting a cached clearance when the store holds one; a challenge
  # means that clearance (if any) is dead, so it is dropped and a fresh one is
  # resolved, up to `max_retries` times. The parsed output is checked against
  # the site's Coverage::Contract, so a cleared page the parser no longer
  # understands comes back flagged in `degraded`, never as a silent success.
  # Progress is narrated to an injected EventSink (fast_path, solving); the
  # result is still returned.
  class ScrapeFlow
    def initialize(site:, fetcher:, detector:, store:, max_retries: 1, events: NullEventSink.new, proxy: nil)
      @site = site
      @fetcher = fetcher
      @detector = detector
      @store = store
      @max_retries = max_retries
      @events = events
      @proxy = proxy
    end

    def run(path)
      started = monotonic_ms
      url = @site.url_for(path)
      # The clearance is bound to the TLS profile and egress IP that solved it.
      key = ClearanceKey.new(site_id: @site.id, profile: @site.profile, proxy: @proxy)
      clearance = @store.peek(key, refresh_url: url) # may also refresh ahead, in the background
      browser_used = false
      retries = 0

      response = fetch(url, clearance, attempt: 1)
      while (challenge = @detector.detect(response))
        # Whatever we presented did not clear — expired early or never worked —
        # so drop it before this request or the next one reuses it.
        @store.invalidate(key, clearance) if clearance
        raise RetryBudgetExhausted if retries >= @max_retries

        retries += 1
        @events.emit(:solving, kind: challenge.kind)
        clearance = @store.clearance(key, url, challenge)
        browser_used = true
        response = fetch(url, clearance, attempt: retries + 1)
      end

      # Checked as the API renders it: the same data the controller renders.
      data = @site.parser.parse_page(response.body).data
      report = Coverage::Check.new(@site.contract).call(data)
      ScrapeResult.new(
        site: @site.id,
        data: data,
        browser_used: browser_used,
        latency_ms: (monotonic_ms - started).round,
        coverage: report.coverage,
        degraded: (report.issues unless report.issues.empty?)
      )
    end

    private

    # Replays the clearance's cookies, headers, and UA together — they are bound
    # to each other — or fetches bare when there is none.
    def fetch(url, clearance, attempt:)
      @events.emit(:fast_path, attempt: attempt, clearance: !clearance.nil?)
      @fetcher.fetch(
        url,
        ua: clearance&.ua,
        cookies: clearance&.cookies || {},
        headers: clearance&.headers || {},
        **{ proxy: @proxy }.compact # no proxy: the plain call
      )
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
