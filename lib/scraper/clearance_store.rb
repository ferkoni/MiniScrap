module Scraper
  # The one long-lived mutable object: Clearances keyed by ClearanceKey, shared
  # by every request (the edge injects a process-wide instance), so one
  # expensive solve is reused across many cheap fetches.
  #
  # Reactive: it solves only on a miss — nothing cached yet, the TTL elapsed,
  # or the fast path reported the clearance dead via #invalidate. Not yet
  # thread-safe; slice #4 wraps #clearance in a per-key single-flight lock.
  class ClearanceStore
    def initialize(registry:, clock: -> { Time.now })
      @registry = registry
      @clock = clock
      @entries = {}
    end

    # The cached clearance if it is still valid; never solves.
    def peek(key)
      clearance = @entries[key]
      clearance if clearance&.valid_at?(@clock.call)
    end

    # A valid clearance for the key, solving (routed by the challenge's kind)
    # and caching one on a miss. Raises UnsupportedChallenge for an unrouted
    # kind, caching nothing.
    def clearance(key, url, challenge)
      peek(key) || (@entries[key] = @registry.for(challenge).solve(url, challenge))
    end

    # Drops the clearance the fast path found dead — but only if it is still
    # the cached one, so a caller holding a stale clearance never evicts a
    # fresher one another request has already solved.
    def invalidate(key, clearance)
      @entries.delete(key) if @entries[key] == clearance
    end
  end
end
