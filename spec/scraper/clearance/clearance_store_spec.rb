require "rails_helper"
require_relative "../../support/gated_solver"
require_relative "../../support/redis_helper"

# The reactive store: solve on a miss, serve a valid clearance until it
# expires, and drop one the fast path reports dead — with a per-key
# single-flight solve so a concurrent herd costs one browser, not N.
#
# One contract, two backends: every example below runs against the in-memory
# backend and, with REDIS_URL set, against Redis (see the bottom of the file).
RSpec.shared_examples "a clearance store" do
  let(:now) { Time.utc(2026, 1, 1, 12, 0, 0) }
  let(:clock) { -> { now } }
  let(:solver) { Scraper::StubSolver.new(clock: clock, ttl: 1800) }
  let(:store) { described_class.new(registry: Scraper::SolverRegistry.new(cloudflare_js: solver), backend: backend, clock: clock) }

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
    let(:store) { described_class.new(registry: Scraper::SolverRegistry.new(cloudflare_js: gated), backend: backend, clock: clock) }

    # Counts callers that have joined an in-flight solve, so a spec releases
    # the leader only once the herd is genuinely waiting on it. (A parked
    # thread is not enough: with Redis it may still be queued on the
    # connection, about to *lead* a fresh flight once this one finishes.)
    let(:joined) { Concurrent::AtomicFixnum.new }

    before do
      allow(backend).to receive(:join).and_wrap_original do |original, *args|
        original.call(*args).tap { |flight| joined.increment if flight }
      end
    end

    def await_joined(count)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GatedSolver::WAIT
      until joined.value >= count
        raise "only #{joined.value} of #{count} callers joined the flight" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        Thread.pass
      end
    end

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
      await_joined(herd - 1)
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
        await_joined(herd - 1)
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

  # Proactive refresh-ahead (XFetch, Vattani et al. VLDB 2015): a read of a
  # still-valid clearance may start a background re-solve ahead of expiry, so
  # active traffic never pays the periodic cold hit. The gate fires when
  #   now + delta * beta * -ln(rand) >= expires_at
  # with delta the measured cost of the last solve. rand and the clock are
  # injected, so the gate is deterministic here.
  describe "refresh-ahead" do
    let(:t0) { Time.utc(2026, 1, 1, 12, 0, 0) }
    let(:times) { [t0] }
    let(:clock) { -> { times.last } }
    let(:cost) { 10 } # seconds a solve takes, as measured by the store
    let(:log) { StringIO.new }
    let(:executor) { :immediate }
    let(:store) do
      described_class.new(
        registry: Scraper::SolverRegistry.new(cloudflare_js: timed_solver),
        backend: backend,
        clock: clock,
        rand: -> { Math.exp(-1) }, # -ln(rand) == 1, so the expected lead is exactly delta * beta
        beta: 1.0,
        executor: executor,
        logger: Logger.new(log)
      )
    end

    # A solver whose solves take `cost` seconds of (injected) wall time, each
    # returning a distinct clearance valid for 1800s from when it finished.
    let(:timed_solver) do
      times = self.times
      cost = self.cost
      Class.new do
        include Scraper::Solver
        attr_reader :calls

        define_method(:solve) do |_url, _challenge, proxy: nil|
          @calls = @calls.to_i + 1
          times << times.last + cost
          Scraper::Clearance.new(cookies: { "cf_clearance" => "v#{@calls}" }, headers: {}, ua: "UA", expires_at: times.last + 1800)
        end
      end.new
    end

    let(:expires_at) { t0 + cost + 1800 }

    before { store.clearance(key, url, challenge) }

    def read_at(time)
      times << time
      store.peek(key, refresh_url: url)
    end

    it "records the measured cost of the solve" do
      expect(store.entry(key).delta).to eq(cost)
    end

    it "fires at T - lead (lead = delta * beta)" do
      read_at(expires_at - cost)
      expect(timed_solver.calls).to eq(2)
    end

    it "does not fire at T - 2 * lead" do
      read_at(expires_at - 2 * cost)
      expect(timed_solver.calls).to eq(1)
    end

    it "replaces the entry with the refreshed clearance" do
      read_at(expires_at - cost)
      expect(store.peek(key).cookies).to eq("cf_clearance" => "v2")
    end

    it "never refreshes on a plain peek (no refresh_url)" do
      times << expires_at - cost
      store.peek(key)
      expect(timed_solver.calls).to eq(1)
    end

    it "does not refresh a hard-expired clearance (the reactive path owns that)" do
      expect(read_at(expires_at + 1)).to be_nil
      expect(timed_solver.calls).to eq(1)
    end

    it "logs the background solve, which no request is waiting on" do
      read_at(expires_at - cost)
      expect(log.string).to include("refresh-ahead started", "refresh-ahead completed")
    end

    context "when the background solve fails" do
      before do
        allow(timed_solver).to receive(:solve).and_raise(Scraper::SolveFailed, "boom")
      end

      it "keeps serving the still-valid clearance and logs the failure" do
        expect(read_at(expires_at - cost).cookies).to eq("cf_clearance" => "v1")
        expect(store.peek(key).cookies).to eq("cf_clearance" => "v1")
        expect(log.string).to include("refresh-ahead failed", "boom")
      end
    end

    # Real background threads: the reader must return at once with the current
    # clearance, and a crowd crossing the gate must share one solve.
    context "with a real background executor" do
      let(:executor) { :io }
      let(:gated) { GatedSolver.new(-> { Scraper::Clearance.new(cookies: { "cf_clearance" => "fresh" }, headers: {}, ua: "UA", expires_at: expires_at + 1800) }) }

      before do
        # Swap the solver for a gated one only after the initial timed solve.
        allow(timed_solver).to receive(:solve) { |url, challenge| gated.solve(url, challenge) }
      end

      it "serves the current clearance without waiting on the refresh" do
        served = read_at(expires_at - cost)

        expect(served.cookies).to eq("cf_clearance" => "v1")
        expect(gated.wait_until_entered).to be(true)
        gated.release
      end

      it "starts exactly one background solve for a crowd crossing the gate" do
        times << expires_at - cost
        readers = Array.new(5) { Thread.new { store.peek(key, refresh_url: url) } }
        readers.each(&:join)
        expect(gated.wait_until_entered).to be(true)
        gated.release

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GatedSolver::WAIT
        Thread.pass until store.peek(key)&.cookies == { "cf_clearance" => "fresh" } || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        expect(store.peek(key).cookies).to eq("cf_clearance" => "fresh")
        expect(gated.calls).to eq(1)
      end
    end
  end
end

RSpec.describe Scraper::ClearanceStore do
  context "with the in-memory backend" do
    let(:backend) { described_class::MemoryBackend.new }

    it_behaves_like "a clearance store"
  end

  # Same examples, entries and flights in Redis. A fresh namespace per example
  # keeps them isolated without flushing a shared database.
  context "with the Redis backend", :redis do
    let(:backend) { redis_backend }

    it_behaves_like "a clearance store"
  end
end
