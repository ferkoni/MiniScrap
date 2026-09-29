module Scraper
  # The orchestrator. Site- and protection-agnostic: it talks only to injected
  # interfaces and *returns* a ScrapeResult (or raises) — it knows nothing about
  # Rails, JSON, or HTTP.
  #
  # fast fetch -> detect -> (on a challenge) resolve a clearance through the
  # shared ClearanceStore -> bounded retry -> follow-ups -> parse. The fast
  # path always goes first, presenting a cached clearance when the store holds
  # one; a challenge means that clearance (if any) is dead, so it is dropped
  # and a fresh one is resolved, up to `max_retries` times. The parsed output
  # is checked against
  # the endpoint's Coverage::Contract, so a cleared page the parser no longer
  # understands comes back flagged in `degraded`, never as a silent success.
  #
  # Follow-ups are the background requests a parser declares for content the
  # page's scripts would load (Parser#follow_ups). They run after the cleared
  # page, in order, one attempt each with the same clearance; a failed one is
  # a `follow_up_failed` issue in `degraded` and a nil body for the parser,
  # never a failed scrape: the page itself was fine.
  #
  # Progress is narrated to an injected EventSink (fast_path, solving,
  # follow_up); the result is still returned.
  class ScrapeFlow
    # `parser` reads this endpoint's page (and declares its follow-ups);
    # `contract` is what its output must meet, by default only that it isn't
    # empty.
    def initialize(site:, parser:, fetcher:, detector:, store:, contract: Coverage::Contract::DEFAULT,
                   max_retries: 1, events: NullEventSink.new, proxy: nil)
      @site = site
      @parser = parser
      @contract = contract
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

      bodies, failures = fetch_follow_ups(clearance)
      # Checked as the API renders it: the same data the controller renders.
      data = @parser.parse_page(response.body, follow_ups: bodies).data
      report = Coverage::Check.new(@contract).call(data)
      issues = failures + report.issues
      ScrapeResult.new(
        site: @site.id,
        data: data,
        browser_used: browser_used,
        latency_ms: (monotonic_ms - started).round,
        coverage: report.coverage,
        degraded: (issues unless issues.empty?)
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

    # Each follow-up's body by name (nil when it failed), and one issue per
    # failure.
    def fetch_follow_ups(clearance)
      bodies = {}
      failures = []
      @parser.follow_ups.each do |follow_up|
        body, reason = fetch_follow_up(follow_up, clearance)
        bodies[follow_up.name] = body
        failures << { "code" => "follow_up_failed", "name" => follow_up.name.to_s, "reason" => reason } if reason
      end
      [bodies, failures]
    end

    # One attempt, with the page's clearance, UA and proxy. A challenge is a
    # failure, not solved, and the clearance is kept: the page fetch just
    # proved it works.
    def fetch_follow_up(follow_up, clearance)
      @events.emit(:follow_up, name: follow_up.name)
      response = @fetcher.fetch(
        @site.url_for(follow_up.path),
        ua: clearance&.ua,
        cookies: clearance&.cookies || {},
        headers: (clearance&.headers || {}).merge(follow_up.headers),
        **{ proxy: @proxy }.compact
      )
      return [nil, "challenge"] if @detector.detect(response)
      return [nil, "status #{response.status}"] unless (200..299).cover?(response.status)

      [response.body, nil]
    rescue FetchFailed
      [nil, "fetch_failed"]
    end

    def monotonic_ms
      Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    end
  end
end
