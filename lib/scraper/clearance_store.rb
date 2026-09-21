module Scraper
  # The one long-lived mutable object: Clearances keyed by ClearanceKey, shared
  # by every request (the edge injects a process-wide instance), so one
  # expensive solve is reused across many cheap fetches.
  #
  # Reactive: it solves only on a miss — nothing cached yet, the TTL elapsed,
  # or the fast path reported the clearance dead via #invalidate.
  #
  # Single-flight, per key: when N callers miss on the same key at once, the
  # first becomes the leader and solves; the rest wait on its in-flight solve
  # and share the outcome — one browser for the whole herd. If the solve fails,
  # every waiter raises the leader's error rather than promoting itself to
  # leader (a retry storm), and nothing is cached, so the next request after
  # the burst starts a fresh attempt. Only the short bookkeeping runs under the
  # guard; the solve itself does not, so different keys solve in parallel.
  #
  # Proactive refresh-ahead (XFetch — Vattani et al., "Optimal Probabilistic
  # Cache Stampede Prevention", VLDB 2015): a read that passes `refresh_url`
  # may start a background re-solve of a still-valid clearance, firing when
  #
  #   now + delta * beta * -ln(rand) >= expires_at
  #
  # where delta is the measured cost of the solve that produced it. Expensive
  # clearances start refreshing earlier; rand spreads readers out. The refresh
  # joins the same per-key flight map, so it never races a reactive solve, and
  # it never blocks the reader, who is served the current clearance. Nobody
  # waits on it, so it reports to the logger rather than to any response.
  # XFetch only anticipates scheduled expiry; early death stays reactive.
  class ClearanceStore
    # A cached clearance plus what it takes to refresh it: the measured solve
    # cost (XFetch's delta, in seconds) and the challenge it cleared (to route
    # the re-solve).
    Entry = Data.define(:clearance, :delta, :challenge)

    attr_reader :registry

    # beta scales how early refreshes start (0 disables refresh-ahead). rand
    # must return a value in (0, 1]. executor runs background refreshes
    # (Concurrent::Promises executor; :immediate makes them synchronous).
    def initialize(registry:, clock: -> { Time.now }, beta: 1.0, rand: -> { 1.0 - Random.rand }, executor: :io, logger: Logger.new(nil))
      @registry = registry
      @clock = clock
      @beta = beta
      @rand = rand
      @executor = executor
      @logger = logger
      @entries = Concurrent::Map.new
      @flights = {}
      @guard = Mutex.new
    end

    # The cached clearance if it is still valid; never solves, never blocks.
    # With `refresh_url`, a valid clearance close enough to expiry also starts
    # a background refresh (XFetch) — the caller still gets the current one.
    def peek(key, refresh_url: nil)
      entry = @entries[key]
      now = @clock.call
      return unless entry&.clearance&.valid_at?(now)

      refresh_ahead(key, refresh_url, entry) if refresh_url && refresh_due?(entry, now)
      entry.clearance
    end

    # The raw cached Entry (clearance + solve cost), valid or not.
    def entry(key)
      @entries[key]
    end

    # A valid clearance for the key: the cached one, or the outcome of a solve
    # (routed by the challenge's kind) that this caller leads or joins. Raises
    # the solve's error — UnsupportedChallenge, SolveFailed, SolveTimeout —
    # to the leader and every waiter alike, caching nothing.
    def clearance(key, url, challenge)
      leader = false
      flight = @guard.synchronize do
        # Re-checked under the guard: a flight may have landed since the
        # caller's last peek.
        cached = peek(key)
        return cached if cached

        @flights[key] ||= begin
          leader = true
          Concurrent::Promises.resolvable_future
        end
      end

      solve(key, url, challenge, flight) if leader
      flight.value!
    end

    # Drops the clearance the fast path found dead — but only if it is still
    # the cached one (an atomic compare-and-delete), so a caller holding a
    # stale clearance never evicts a fresher one another request has solved.
    def invalidate(key, clearance)
      @entries.compute_if_present(key) { |entry| entry unless entry.clearance == clearance }
    end

    private

    def refresh_due?(entry, now)
      now + entry.delta * @beta * -Math.log(@rand.call) >= entry.clearance.expires_at
    end

    # Starts a background re-solve unless one is already in flight for the key
    # (then it simply rides that one). Never waits on it.
    def refresh_ahead(key, url, entry)
      flight = @guard.synchronize do
        next if @flights.key?(key)

        @flights[key] = Concurrent::Promises.resolvable_future
      end
      return unless flight

      @logger.info("[ClearanceStore] refresh-ahead started for #{key.site_id} (expires #{entry.clearance.expires_at.utc.iso8601}, last solve #{entry.delta.round(1)}s)")
      Concurrent::Promises.future_on(@executor) do
        solve(key, url, entry.challenge, flight)
        if flight.fulfilled?
          @logger.info("[ClearanceStore] refresh-ahead completed for #{key.site_id} in #{@entries[key].delta.round(1)}s")
        else
          @logger.warn("[ClearanceStore] refresh-ahead failed for #{key.site_id}: #{flight.reason.message} — still serving the current clearance")
        end
      end
    end

    # The leader's half: run the one solve, publish its outcome to the flight,
    # then retire the flight so the next miss starts afresh.
    def solve(key, url, challenge, flight)
      started = @clock.call
      clearance = @registry.for(challenge).solve(url, challenge)
      @entries[key] = Entry.new(clearance: clearance, delta: @clock.call - started, challenge: challenge)
      flight.fulfill(clearance)
    rescue StandardError => error
      flight.reject(error)
    ensure
      @guard.synchronize { @flights.delete(key) }
      # Never leave waiters parked on a flight the leader abandoned (e.g. its
      # thread was killed mid-solve).
      flight.reject(SolveFailed.new("the solve was aborted"), false) unless flight.resolved?
    end
  end
end
