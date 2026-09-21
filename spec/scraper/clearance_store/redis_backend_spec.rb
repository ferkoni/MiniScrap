require "rails_helper"
require_relative "../../support/gated_solver"
require_relative "../../support/redis_helper"

# What only a shared store can promise: guarantees that hold ACROSS processes.
# Each "process" here is its own ClearanceStore + RedisBackend with its own
# Redis connection — they share nothing but Redis, exactly like two app
# servers. (The single-process contract runs against this backend too, in
# clearance_store_spec.rb.)
RSpec.describe Scraper::ClearanceStore::RedisBackend, :redis do
  let(:now) { Time.utc(2026, 1, 1, 12, 0, 0) }
  let(:clock) { -> { now } }
  let(:key) { Scraper::ClearanceKey.new(site_id: "nissei", profile: :chrome146) }
  let(:url) { "https://nissei.com/py/catalogsearch/result/?q=ps5" }
  let(:challenge) { Scraper::Challenge.new(kind: :cloudflare_js, evidence: { status: 403 }) }
  let(:clearance) { Scraper::Clearance.new(cookies: { "cf_clearance" => "solved" }, headers: {}, ua: "UA", expires_at: now + 1800) }

  # Callers (in any process) that have joined an in-flight solve.
  let(:joined) { Concurrent::AtomicFixnum.new }

  def process(solver, **store_options)
    backend = redis_backend(**store_options.slice(:lock_ttl))
    allow(backend).to receive(:join).and_wrap_original do |original, *args|
      original.call(*args).tap { |flight| joined.increment if flight }
    end
    store = Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new(cloudflare_js: solver), backend: backend, clock: clock,
                                        **store_options.except(:lock_ttl))
    [store, backend]
  end

  # Releases the leader only once `count` callers are genuinely waiting on it.
  def await_joined(count)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GatedSolver::WAIT
    until joined.value >= count
      raise "only #{joined.value} of #{count} callers joined" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  def herd(store, count)
    Array.new(count) do
      Thread.new do
        store.clearance(key, url, challenge)
      rescue Scraper::Error => error
        error
      end
    end
  end

  describe "single-flight across processes" do
    let(:gated) { GatedSolver.new(-> { clearance }) }

    it "collapses a cold herd spread over two processes onto exactly one solve" do
      store_a, = process(gated)
      store_b, = process(gated)

      threads = herd(store_a, 3) + herd(store_b, 3)
      expect(gated.wait_until_entered).to be(true)
      await_joined(5)
      gated.release

      expect(threads.map(&:value)).to all(eq(clearance))
      expect(gated.calls).to eq(1)
      expect(store_b.peek(key)).to eq(clearance)
    end

    it "fails the other process's waiters with the leader's error, and caches nothing" do
      failing = GatedSolver.new(-> { raise Scraper::SolveTimeout, "Timeout after 60.0 seconds" })
      store_a, = process(failing)
      store_b, = process(failing)

      leader = herd(store_a, 1)
      expect(failing.wait_until_entered).to be(true)
      waiters = herd(store_b, 3)
      await_joined(3)
      failing.release

      expect((leader + waiters).map(&:value)).to all(be_a(Scraper::SolveTimeout).and(have_attributes(message: /Timeout after 60/)))
      expect(failing.calls).to eq(1)
      expect(store_b.peek(key)).to be_nil
    end
  end

  # A leader that dies mid-solve (its process killed) never publishes an
  # outcome and never releases its lock; the lock's expiry bounds the damage.
  describe "a crashed leader" do
    it "fails its waiters once the lock expires, and the next request leads afresh" do
      solver = Scraper::StubSolver.new(clock: clock)
      _, crashed_backend = process(solver, lock_ttl: 0.3)
      store_b, = process(solver, lock_ttl: 0.3)
      crashed_backend.lead(key) # takes the flight, then "dies"

      expect { store_b.clearance(key, url, challenge) }.to raise_error(Scraper::SolveFailed, /abandoned/)
      expect(store_b.clearance(key, url, challenge).cookies).to eq(Scraper::StubSolver::COOKIES)
      expect(solver.calls).to eq(1)
    end
  end

  describe "invalidation across processes" do
    it "never lets a stale caller in one process evict a fresher clearance solved in another" do
      store_a, = process(Scraper::StubSolver.new(clock: clock))
      store_b, = process(Scraper::StubSolver.new(clock: clock))
      stale = clearance.with(cookies: { "cf_clearance" => "old" })
      fresh = store_a.clearance(key, url, challenge)

      store_b.invalidate(key, stale)
      expect(store_a.peek(key)).to eq(fresh)

      store_b.invalidate(key, store_b.peek(key))
      expect(store_a.peek(key)).to be_nil
    end
  end

  describe "refresh-ahead across processes" do
    it "starts at most one background solve for readers crossing the gate in different processes" do
      gated = GatedSolver.new(-> { clearance.with(cookies: { "cf_clearance" => "fresh" }, expires_at: now + 3600) })
      options = { rand: -> { Math.exp(-1) }, executor: :io }
      store_a, backend = process(gated, **options)
      store_b, = process(gated, **options)
      backend.write(key, Scraper::ClearanceStore::Entry.new(clearance: clearance, delta: 1800.0, challenge: challenge), ttl: 1800)

      readers = Array.new(3) { Thread.new { store_a.peek(key, refresh_url: url) } } +
        Array.new(3) { Thread.new { store_b.peek(key, refresh_url: url) } }
      expect(readers.map(&:value)).to all(eq(clearance)) # served at once, not after the refresh
      expect(gated.wait_until_entered).to be(true)
      gated.release

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + GatedSolver::WAIT
      Thread.pass until store_b.peek(key)&.cookies == { "cf_clearance" => "fresh" } || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      expect(store_b.peek(key).cookies).to eq("cf_clearance" => "fresh")
      expect(gated.calls).to eq(1)
    end
  end

  describe "what lands in Redis" do
    let(:redis) { Redis.new(url: ENV.fetch("REDIS_URL")) }

    it "round-trips a clearance exactly, to the nanosecond" do
      precise = clearance.with(expires_at: Time.at(1_800_000_000, 123_456_789, :nsec).utc)
      backend = redis_backend
      backend.write(key, Scraper::ClearanceStore::Entry.new(clearance: precise, delta: 13.2, challenge: challenge), ttl: 60)

      entry = backend.read(key)
      expect(entry.clearance).to eq(precise)
      expect(entry.delta).to eq(13.2)
      expect(entry.challenge).to eq(challenge)
    end

    it "expires the entry with the clearance" do
      backend = redis_backend
      backend.write(key, Scraper::ClearanceStore::Entry.new(clearance: clearance, delta: 1.0, challenge: challenge), ttl: 42)

      expect(redis.pttl(redis.keys("#{redis_namespace}:clearance:*").first)).to be_between(41_000, 42_000)
    end

    # Proxy URLs carry credentials; keys are visible to anyone with Redis access.
    it "never puts a proxy's credentials in a key" do
      proxied = key.with(proxy: "http://user:s3cret@proxy.example:8080")
      backend = redis_backend
      backend.write(proxied, Scraper::ClearanceStore::Entry.new(clearance: clearance, delta: 1.0, challenge: challenge), ttl: 60)
      backend.lead(proxied)

      keys = redis.keys("#{redis_namespace}:*")
      expect(keys.size).to eq(2)
      expect(keys.join).not_to include("s3cret", "proxy.example")
    end
  end
end
