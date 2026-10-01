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
  # leader (a retry storm), and no clearance is cached. Only the short
  # bookkeeping runs under the guard; the solve itself does not, so different
  # keys solve in parallel.
  #
  # A failed solve is remembered: when the solver reports SolveFailed or
  # SolveTimeout (FlareSolverr down, the site refusing the IP), the key's
  # next requests re-raise that error for `failure_ttl` seconds without
  # solving, and refresh-ahead holds off too. A site that just refused a
  # solve isn't asked again at once, and a burst doesn't pay for a doomed
  # attempt each time. After the window, the next request tries afresh.
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
  #
  # Capped: at most `max_solves` solves (reactive or refresh-ahead) run at
  # once in this process, each holding a browser for up to a minute. A leader
  # that finds every slot taken raises SolverBusy at once, and so does every
  # waiter on its flight, rather than queueing. Only leaders take a slot:
  # waiters on an in-flight solve cost nothing extra.
  class ClearanceStore
    # A cached clearance plus what it takes to refresh it: the measured solve
    # cost (XFetch's delta, in seconds) and the challenge it cleared (to route
    # the re-solve).
    Entry = Data.define(:clearance, :delta, :challenge)

    # A failed solve, re-raised for its key until expires_at. Holds the error's
    # class and message, not the error, so it can cross processes and every
    # caller raises an error of its own.
    Failure = Data.define(:error_class, :message, :expires_at) do
      def valid_at?(time)
        time < expires_at
      end

      def error
        error_class.new("#{message} (remembered: no new solve before #{expires_at.utc.iso8601})")
      end
    end

    attr_reader :registry, :backend

    # backend: where entries and in-flight solves live — MemoryBackend (one
    # process) or RedisBackend (shared by every process). beta scales how early
    # refreshes start (0 disables refresh-ahead). rand must return a value in
    # (0, 1]. executor runs background refreshes (Concurrent::Promises
    # executor; :immediate makes them synchronous). max_solves caps concurrent
    # solves in this process (nil: no cap). failure_ttl is how many seconds a
    # failed solve is remembered (0: not at all).
    def initialize(registry:, backend: MemoryBackend.new, clock: -> { Time.now }, beta: 1.0, rand: -> { 1.0 - Random.rand }, executor: :io, logger: Logger.new(nil),
                   max_solves: nil, failure_ttl: 60)
      @registry = registry
      @backend = backend
      @clock = clock
      @beta = beta
      @rand = rand
      @executor = executor
      @logger = logger
      @solve_slots = max_solves && Concurrent::Semaphore.new(max_solves)
      @failure_ttl = failure_ttl
    end

    # The cached clearance if it is still valid; never solves, never blocks.
    # With `refresh_url`, a valid clearance close enough to expiry also starts
    # a background refresh (XFetch) — the caller still gets the current one.
    def peek(key, refresh_url: nil)
      entry = @backend.read(key)
      now = @clock.call
      return unless entry&.clearance&.valid_at?(now)

      refresh_ahead(key, refresh_url, entry) if refresh_url && refresh_due?(entry, now)
      entry.clearance
    end

    # The raw cached Entry (clearance + solve cost), valid or not.
    def entry(key)
      @backend.read(key)
    end

    # A valid clearance for the key: the cached one, or the outcome of a solve
    # (routed by the challenge's kind) that this caller leads or joins. Raises
    # the solve's error — UnsupportedChallenge, SolverBusy, SolveFailed,
    # SolveTimeout — to the leader and every waiter alike, caching no
    # clearance. While a failed solve is remembered, raises its error without
    # solving.
    def clearance(key, url, challenge)
      loop do
        cached = peek(key)
        return cached if cached

        failure = recent_failure(key)
        raise failure.error if failure

        solver = @registry.for(challenge) # an unrouted kind fails before any flight
        if (flight = @backend.lead(key))
          return lead(key, url, challenge, solver, flight)
        elsif (flight = @backend.join(key))
          return flight.value!
        end
        # The flight finished between lead and join: look again.
      end
    end

    # Drops the clearance the fast path found dead — but only if it is still
    # the cached one (an atomic compare-and-delete), so a caller holding a
    # stale clearance never evicts a fresher one another request has solved.
    def invalidate(key, clearance)
      @backend.delete_if_current(key, clearance)
    end

    private

    def refresh_due?(entry, now)
      now + entry.delta * @beta * -Math.log(@rand.call) >= entry.clearance.expires_at
    end

    # Starts a background re-solve unless one is already in flight for the key
    # (then it simply rides that one) or the last solve for the key failed
    # recently. Never waits on it.
    def refresh_ahead(key, url, entry)
      return if recent_failure(key)

      flight = @backend.lead(key)
      return unless flight

      @logger.info("[ClearanceStore] refresh-ahead started for #{key.site_id} (expires #{entry.clearance.expires_at.utc.iso8601}, last solve #{entry.delta.round(1)}s)")
      Concurrent::Promises.future_on(@executor) do
        lead(key, url, entry.challenge, @registry.for(entry.challenge), flight, refreshing: true)
        @logger.info("[ClearanceStore] refresh-ahead completed for #{key.site_id} in #{@backend.read(key).delta.round(1)}s")
      rescue StandardError => error
        @logger.warn("[ClearanceStore] refresh-ahead failed for #{key.site_id}: #{error.message} — still serving the current clearance")
      end
    end

    # The leader's half: run the one solve, publish its outcome to the flight
    # (waking every waiter, in this process or another), then retire it. A
    # reactive leader first re-checks the cache — a solve may have landed, or
    # failed, while it raced for the flight; a refresh-ahead leader must solve
    # regardless.
    def lead(key, url, challenge, solver, flight, refreshing: false)
      unless refreshing
        if (cached = peek(key))
          flight.fulfill(cached)
          return cached
        end
        failure = recent_failure(key)
        raise failure.error if failure
      end

      started = @clock.call
      clearance = solve(key, url, challenge, solver)
      finished = @clock.call
      @backend.write(key, Entry.new(clearance: clearance, delta: finished - started, challenge: challenge),
        ttl: clearance.expires_at - finished)
      flight.fulfill(clearance)
      clearance
    rescue StandardError => error
      flight.reject(error)
      raise
    ensure
      flight.finish
    end

    # The key's failed solve, while it is still remembered.
    def recent_failure(key)
      failure = @backend.read_failure(key)
      failure if failure&.valid_at?(@clock.call)
    end

    # Runs the solve, remembering a failure the solver reports. SolverBusy is
    # this process's own load, not the site's answer, so it isn't remembered.
    def solve(key, url, challenge, solver)
      with_solve_slot { solver.solve(url, challenge, **{ proxy: key.proxy }.compact) } # no proxy: the plain call
    rescue SolveFailed, SolveTimeout => error
      remember_failure(key, error)
      raise
    end

    def remember_failure(key, error)
      return unless @failure_ttl.positive?

      failure = Failure.new(error_class: error.class, message: error.message, expires_at: @clock.call + @failure_ttl)
      @backend.write_failure(key, failure, ttl: @failure_ttl)
    end

    # Runs one solve in a free slot, or raises SolverBusy when there is none:
    # failing fast beats queueing a request behind solves that can take a
    # minute.
    def with_solve_slot
      return yield unless @solve_slots
      raise SolverBusy unless @solve_slots.try_acquire

      begin
        yield
      ensure
        @solve_slots.release
      end
    end
  end
end
