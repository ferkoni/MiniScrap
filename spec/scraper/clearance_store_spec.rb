require "rails_helper"

# The reactive store: solve on a miss, serve a valid clearance until it
# expires, and drop one the fast path reports dead. Single-threaded here; the
# per-key single-flight lock arrives in slice #4.
RSpec.describe Scraper::ClearanceStore do
  let(:now) { Time.utc(2026, 1, 1, 12, 0, 0) }
  let(:clock) { -> { now } }
  let(:solver) { Scraper::StubSolver.new(clock: clock, ttl: 1800) }
  let(:store) { described_class.new(registry: Scraper::SolverRegistry.new(cloudflare_js: solver), clock: clock) }

  let(:key) { Scraper::ClearanceKey.new(site_id: "nissei") }
  let(:url) { "https://nissei.com/py/search?q=ps5" }
  let(:challenge) { Scraper::Challenge.new(kind: :cloudflare_js, evidence: { status: 403 }) }

  describe "#peek" do
    it "is nil before anything was solved" do
      expect(store.peek(key)).to be_nil
    end

    it "does not solve" do
      store.peek(key)
      expect(solver.calls).to eq(0)
    end
  end

  describe "#clearance" do
    it "solves on a miss and caches the result under the key" do
      clearance = store.clearance(key, url, challenge)

      expect(solver.calls).to eq(1)
      expect(store.peek(key)).to eq(clearance)
    end

    it "passes the url and challenge through to the routed solver" do
      expect(solver).to receive(:solve).with(url, challenge).and_call_original
      store.clearance(key, url, challenge)
    end

    it "serves a still-valid cached clearance without solving again" do
      first = store.clearance(key, url, challenge)

      expect(store.clearance(key, url, challenge)).to eq(first)
      expect(solver.calls).to eq(1)
    end

    it "keeps clearances for different keys apart" do
      store.clearance(key, url, challenge)

      expect(store.peek(Scraper::ClearanceKey.new(site_id: "other"))).to be_nil
    end

    it "raises UnsupportedChallenge for a kind with no registered solver" do
      datadome = Scraper::Challenge.new(kind: :datadome, evidence: {})

      expect { store.clearance(key, url, datadome) }.to raise_error(Scraper::UnsupportedChallenge)
      expect(store.peek(key)).to be_nil
    end
  end

  context "when the clearance's TTL has elapsed" do
    let(:times) { [now] }
    let(:clock) { -> { times.last } }

    before do
      store.clearance(key, url, challenge)
      times << now + 1801
    end

    it "no longer serves it" do
      expect(store.peek(key)).to be_nil
    end

    it "re-solves on the next request" do
      store.clearance(key, url, challenge)
      expect(solver.calls).to eq(2)
    end
  end

  describe "#invalidate" do
    it "drops the cached clearance the fast path found dead" do
      dead = store.clearance(key, url, challenge)

      store.invalidate(key, dead)

      expect(store.peek(key)).to be_nil
    end

    # Compare-and-delete: a caller holding an older, dead clearance must not
    # evict a fresher one another request already solved (matters once slice
    # #4 makes requests concurrent).
    it "leaves a newer clearance in place" do
      stale = Scraper::Clearance.new(cookies: { "cf_clearance" => "old" }, headers: {}, ua: "UA", expires_at: now + 60)
      fresh = store.clearance(key, url, challenge)

      store.invalidate(key, stale)

      expect(store.peek(key)).to eq(fresh)
    end
  end
end
