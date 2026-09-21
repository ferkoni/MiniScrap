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
  class ClearanceStore
    def initialize(registry:, clock: -> { Time.now })
      @registry = registry
      @clock = clock
      @entries = Concurrent::Map.new
      @flights = {}
      @guard = Mutex.new
    end

    # The cached clearance if it is still valid; never solves.
    def peek(key)
      clearance = @entries[key]
      clearance if clearance&.valid_at?(@clock.call)
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
      @entries.delete_pair(key, clearance)
    end

    private

    # The leader's half: run the one solve, publish its outcome to the flight,
    # then retire the flight so the next miss starts afresh.
    def solve(key, url, challenge, flight)
      clearance = @registry.for(challenge).solve(url, challenge)
      @entries[key] = clearance
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
