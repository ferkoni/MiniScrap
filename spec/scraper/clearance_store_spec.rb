require "rails_helper"
require_relative "../support/gated_solver"

# The reactive store: solve on a miss, serve a valid clearance until it
# expires, and drop one the fast path reports dead — with a per-key
# single-flight solve so a concurrent herd costs one browser, not N.
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
    # evict a fresher one another concurrent request already solved.
    it "leaves a newer clearance in place" do
      stale = Scraper::Clearance.new(cookies: { "cf_clearance" => "old" }, headers: {}, ua: "UA", expires_at: now + 60)
      fresh = store.clearance(key, url, challenge)

      store.invalidate(key, stale)

      expect(store.peek(key)).to eq(fresh)
    end
  end

  # Single-flight: callers are real threads; GatedSolver holds the solve open
  # until the whole herd has piled up behind it, so the counts are
  # deterministic rather than timing-dependent.
  describe "single-flight" do
    let(:herd) { 5 }
    let(:clearance) { Scraper::Clearance.new(cookies: { "cf_clearance" => "solved" }, headers: {}, ua: "UA", expires_at: now + 1800) }
    let(:gated) { GatedSolver.new(-> { clearance }) }
    let(:store) { described_class.new(registry: Scraper::SolverRegistry.new(cloudflare_js: gated), clock: clock) }

    # Starts `count` concurrent #clearance calls; each thread's value is the
    # Clearance it got or the error it raised.
    def stampede(count, key: self.key)
      Array.new(count) do
        Thread.new do
          store.clearance(key, url, challenge)
        rescue Scraper::Error => error
          error
        end
      end
    end

    it "collapses N concurrent same-key callers onto exactly one solve" do
      threads = stampede(herd)
      expect(gated.wait_until_entered).to be(true)
      GatedSolver.wait_until_blocked(threads)
      gated.release

      expect(threads.map(&:value)).to all(eq(clearance))
      expect(gated.calls).to eq(1)
      expect(store.peek(key)).to eq(clearance)
    end

    it "solves different keys in parallel instead of serialising them" do
      threads = stampede(1) + stampede(1, key: Scraper::ClearanceKey.new(site_id: "other"))

      # Both solves must be in flight at once; a global lock would park the
      # second caller before it ever reached the solver.
      expect(gated.wait_until_entered).to be(true)
      expect(gated.wait_until_entered).to be(true)
      gated.release(2)

      expect(threads.map(&:value)).to all(eq(clearance))
      expect(gated.calls).to eq(2)
    end

    context "when the leader's solve fails" do
      let(:gated) { GatedSolver.new(-> { raise Scraper::SolveFailed }, -> { clearance }) }

      def failed_burst
        threads = stampede(herd)
        gated.wait_until_entered
        GatedSolver.wait_until_blocked(threads)
        gated.release
        threads.map(&:value)
      end

      it "fails every waiter with the leader's error instead of promoting a new leader" do
        expect(failed_burst).to all(be_a(Scraper::SolveFailed))
        expect(gated.calls).to eq(1)
      end

      it "caches nothing" do
        failed_burst
        expect(store.peek(key)).to be_nil
      end

      it "lets the next request after the burst attempt a fresh solve" do
        failed_burst
        gated.release

        expect(store.clearance(key, url, challenge)).to eq(clearance)
        expect(gated.calls).to eq(2)
      end
    end
  end
end
