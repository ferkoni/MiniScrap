require "rails_helper"
require_relative "../../support/gated_solver"

# The orchestrator runs Rails-free: built from a Site + injected collaborators,
# it returns a ScrapeResult with no controller, no HTTP, no browser.
RSpec.describe Scraper::ScrapeFlow do
  let(:html) { Rails.root.join("spec/fixtures/nissei_search.html").read }
  let(:cleared) { Scraper::Response.new(status: 200, headers: {}, body: html) }
  let(:challenged) { Scraper::Response.new(status: 403, headers: {}, body: "Just a moment...") }

  let(:fetcher) { Scraper::FakeFetcher.new(response: cleared) }
  let(:detector) { Scraper::CompositeDetector.new([Scraper::CloudflareDetector.new]) }

  let(:times) { [Time.utc(2026, 1, 1, 12, 0, 0)] }
  let(:clock) { -> { times.last } }
  let(:solver) { Scraper::StubSolver.new(clock: clock, ttl: 1800) }
  let(:store) { Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new(cloudflare_js: solver), clock: clock) }
  let(:key) { Scraper::ClearanceKey.new(site_id: "nissei", profile: :chrome131) }

  let(:site) do
    Scraper::Site.new(
      id: "nissei",
      base_url: "https://nissei.com/py/",
      profile: :chrome131,
      parser: Scraper::NisseiSearchParser.new
    )
  end
  let(:url) { "https://nissei.com/py/search?q=ps5" }

  def run_flow
    described_class.new(site: site, fetcher: fetcher, detector: detector, store: store).run("search?q=ps5")
  end

  subject(:result) { run_flow }

  context "when the fast path is not challenged" do
    it "returns a ScrapeResult for the site" do
      expect(result).to be_a(Scraper::ScrapeResult)
      expect(result.site).to eq("nissei")
    end

    it "marks the fast path as browser_used: false with a recorded latency" do
      expect(result.browser_used).to be(false)
      expect(result.latency_ms).to be_a(Numeric).and be >= 0
    end

    it "parses the fetched body through the site's parser" do
      expect(result.results.map(&:title)).to include("PlayStation 5 Console")
    end

    it "offers the store a chance to refresh ahead on every read" do
      expect(store).to receive(:peek).with(key, refresh_url: url).and_call_original
      result
    end

    it "fetches the site's composed URL with no clearance on a cold store" do
      expect(fetcher).to receive(:fetch)
        .with(url, ua: nil, cookies: {}, headers: {})
        .and_call_original
      result
    end

    it "never solves" do
      result
      expect(solver.calls).to eq(0)
    end
  end

  # A clean 200 that parses to nothing is a structural anomaly (e.g. the layout
  # moved past every selector), surfaced distinctly — never a silent empty
  # success, and never routed to a solver.
  context "when a clean page parses to zero products" do
    let(:cleared) { Scraper::Response.new(status: 200, headers: {}, body: "<html><body>redesigned</body></html>") }

    it "returns an empty result flagged degraded: zero_results" do
      expect(result.results).to eq([])
      expect(result.degraded).to eq("zero_results")
      expect(solver.calls).to eq(0)
    end
  end

  it "reports degraded: nil when products were found" do
    expect(result.degraded).to be_nil
  end

  # Scenario A: fast path challenged -> one solve -> retried fast path clears.
  context "on a cold start against a challenging site" do
    let(:fetcher) { Scraper::FakeFetcher.new(responses: [challenged, cleared]) }

    it "solves exactly once and returns the parsed results with browser_used: true" do
      expect(result.browser_used).to be(true)
      expect(result.results.map(&:title)).to include("PlayStation 5 Console")
      expect(solver.calls).to eq(1)
    end

    it "retries the fast path presenting the clearance's cookies and UA together" do
      expect(fetcher).to receive(:fetch).with(url, ua: nil, cookies: {}, headers: {}).ordered.and_call_original
      expect(fetcher).to receive(:fetch)
        .with(url, ua: Scraper::StubSolver::UA, cookies: Scraper::StubSolver::COOKIES, headers: {})
        .ordered.and_call_original
      result
    end

    it "caches the clearance in the shared store" do
      result
      expect(store.peek(key)).to be_a(Scraper::Clearance)
    end
  end

  # Scenario B: a second flow sharing the store rides the cached clearance.
  context "on a warm request" do
    let(:fetcher) { Scraper::FakeFetcher.new(responses: [challenged, cleared]) }

    before { run_flow }

    it "presents the cached clearance on the first fetch and skips the solve" do
      warm_fetcher = Scraper::FakeFetcher.new(response: cleared)
      expect(warm_fetcher).to receive(:fetch)
        .with(url, ua: Scraper::StubSolver::UA, cookies: Scraper::StubSolver::COOKIES, headers: {})
        .and_call_original

      warm = described_class.new(site: site, fetcher: warm_fetcher, detector: detector, store: store).run("search?q=ps5")

      expect(warm.browser_used).to be(false)
      expect(solver.calls).to eq(1)
    end

    it "re-solves once the clearance's TTL has elapsed" do
      times << times.first + 1801
      expired_fetcher = Scraper::FakeFetcher.new(responses: [challenged, cleared])
      expect(expired_fetcher).to receive(:fetch).with(url, ua: nil, cookies: {}, headers: {}).ordered.and_call_original
      expect(expired_fetcher).to receive(:fetch).with(url, hash_including(ua: Scraper::StubSolver::UA)).ordered.and_call_original

      expired = described_class.new(site: site, fetcher: expired_fetcher, detector: detector, store: store).run("search?q=ps5")

      expect(expired.browser_used).to be(true)
      expect(solver.calls).to eq(2)
    end
  end

  # Early death: a cached clearance that dies before its TTL draws a fresh 403;
  # the flow drops it and re-solves, within the same retry budget.
  context "when a cached clearance died early" do
    let(:fetcher) { Scraper::FakeFetcher.new(responses: [challenged, cleared]) }

    before { run_flow }

    it "invalidates it, re-solves, and succeeds on the retry" do
      dead = store.peek(key)
      recovering = Scraper::FakeFetcher.new(responses: [challenged, cleared])
      expect(store).to receive(:invalidate).with(key, dead).and_call_original

      recovered = described_class.new(site: site, fetcher: recovering, detector: detector, store: store).run("search?q=ps5")

      expect(recovered.browser_used).to be(true)
      expect(solver.calls).to eq(2)
    end
  end

  # With max_retries = 1, a freshly solved clearance that still draws a
  # challenge exhausts the budget rather than looping on the browser.
  context "when the retried fast path is still challenged" do
    let(:fetcher) { Scraper::FakeFetcher.new(response: challenged) }

    it "raises RetryBudgetExhausted after a single solve" do
      expect { result }.to raise_error(Scraper::RetryBudgetExhausted)
      expect(solver.calls).to eq(1)
    end

    it "drops the clearance that failed so the next request starts cold" do
      expect { result }.to raise_error(Scraper::RetryBudgetExhausted)
      expect(store.peek(key)).to be_nil
    end

    it "does not parse the challenge body" do
      expect(site.parser).not_to receive(:parse)
      expect { result }.to raise_error(Scraper::RetryBudgetExhausted)
    end
  end

  context "when the detected challenge has no registered solver" do
    let(:fetcher) { Scraper::FakeFetcher.new(response: challenged) }
    let(:store) { Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new, clock: clock) }

    it "raises UnsupportedChallenge carrying the detected kind" do
      expect { result }.to raise_error(Scraper::UnsupportedChallenge) do |error|
        expect(error.kind).to eq(:cloudflare_js)
      end
    end

    it "does not parse the challenge body" do
      expect(site.parser).not_to receive(:parse)
      expect { result }.to raise_error(Scraper::UnsupportedChallenge)
    end
  end

  # Scenario C: a cold herd sharing one store rides a single solve. The fetcher
  # clears only a request presenting the solved cookie, so every flow must have
  # picked up the one clearance to succeed.
  context "when a cold herd arrives at once" do
    let(:clearance) { Scraper::Clearance.new(cookies: { "cf_clearance" => "solved" }, headers: {}, ua: "UA", expires_at: times.last + 1800) }
    let(:gated) { GatedSolver.new(-> { clearance }) }
    let(:store) { Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new(cloudflare_js: gated), clock: clock) }
    let(:fetcher) do
      cleared = self.cleared
      challenged = self.challenged
      Class.new do
        include Scraper::Fetcher

        define_method(:fetch) do |_url, ua: nil, cookies: {}, headers: {}|
          cookies.key?("cf_clearance") ? cleared : challenged
        end
      end.new
    end

    it "returns a browser-cleared ScrapeResult to every caller from one solve" do
      threads = Array.new(5) { Thread.new { run_flow } }
      gated.wait_until_entered
      GatedSolver.wait_until_blocked(threads)
      gated.release

      results = threads.map(&:value)
      expect(results).to all(have_attributes(browser_used: true, results: be_present))
      expect(gated.calls).to eq(1)
    end
  end

  # The live-SSE seam: the flow narrates its escalation through an injected
  # EventSink and still returns its ScrapeResult.
  describe "progress events" do
    let(:events) { Scraper::RecordingEventSink.new }

    def run_with_events(fetcher)
      described_class.new(site: site, fetcher: fetcher, detector: detector, store: store, events: events).run("search?q=ps5")
    end

    it "narrates a cold start as fast_path -> solving -> fast_path" do
      result = run_with_events(Scraper::FakeFetcher.new(responses: [challenged, cleared]))

      expect(events.names).to eq(%i[fast_path solving fast_path])
      expect(events.events).to eq(
        [
          [:fast_path, { attempt: 1, clearance: false }],
          [:solving, { kind: :cloudflare_js }],
          [:fast_path, { attempt: 2, clearance: true }]
        ]
      )
      expect(result).to be_a(Scraper::ScrapeResult).and have_attributes(browser_used: true)
    end

    it "narrates a warm request as a single fast_path, with no solving step" do
      run_with_events(Scraper::FakeFetcher.new(responses: [challenged, cleared]))
      events.events.clear

      run_with_events(Scraper::FakeFetcher.new(response: cleared))

      expect(events.events).to eq([[:fast_path, { attempt: 1, clearance: true }]])
    end

    it "emits nothing by default (the plain JSON path has no sink)" do
      expect { result }.not_to raise_error
    end
  end

  # A clearance is bound to the egress IP that solved it, so each proxy gets
  # its own: keyed by (site, profile, proxy), solved through that proxy, and
  # never presented through another.
  describe "proxy-keyed clearances" do
    let(:solver) { Scraper::StubSolver.new(clock: clock, ttl: 1800) }

    def run_via(proxy, fetcher)
      described_class.new(site: site, fetcher: fetcher, detector: detector, store: store, proxy: proxy).run("search?q=ps5")
    end

    it "fetches and solves through the request's proxy, caching under a proxy-specific key" do
      fetcher = Scraper::FakeFetcher.new(responses: [challenged, cleared])
      expect(fetcher).to receive(:fetch).with(url, hash_including(proxy: "http://a:1")).twice.and_call_original
      expect(solver).to receive(:solve).with(url, anything, proxy: "http://a:1").and_call_original

      run_via("http://a:1", fetcher)

      expect(store.peek(key.with(proxy: "http://a:1"))).to be_a(Scraper::Clearance)
      expect(store.peek(key)).to be_nil
    end

    it "never presents a clearance solved through proxy A on a request through proxy B" do
      run_via("http://a:1", Scraper::FakeFetcher.new(responses: [challenged, cleared]))

      via_b = Scraper::FakeFetcher.new(responses: [challenged, cleared])
      expect(via_b).to receive(:fetch).with(url, hash_including(proxy: "http://b:2", cookies: {})).ordered.and_call_original
      expect(via_b).to receive(:fetch).with(url, hash_including(proxy: "http://b:2")).ordered.and_call_original

      expect(run_via("http://b:2", via_b).browser_used).to be(true)
      expect(solver.calls).to eq(2)
    end
  end
end
