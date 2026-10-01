require "digest"
require "json"
require "securerandom"

module Scraper
  class ClearanceStore
    # Keeps entries and in-flight solves in Redis, shared by every process —
    # the scale-out backend. Same guarantees as MemoryBackend, across processes:
    #
    # * Entries: a hash per key (clearance, delta, challenge), expiring with
    #   the clearance. #delete_if_current is an atomic compare-and-delete (Lua).
    # * Single-flight: the leader holds `SET NX PX lock_ttl` on the key, with a
    #   random token. It publishes its outcome under that token (the clearance
    #   or its error), then releases the lock only if it still owns it.
    #   Waiters — in any process — poll for the outcome and re-raise the
    #   leader's error rather than promoting themselves (no retry storm).
    # * A crashed leader never publishes: its lock expires after lock_ttl and
    #   its waiters fail with SolveFailed; the next request leads afresh.
    # * Remembered failures: a JSON value per key, expiring with the failure.
    #
    # Proxy URLs can carry credentials, so the proxy part of a key is hashed.
    class RedisBackend
      # Deletes the entry only if it still holds the given clearance.
      DELETE_IF_CURRENT = <<~LUA.freeze
        if redis.call("HGET", KEYS[1], "clearance") == ARGV[1] then
          return redis.call("DEL", KEYS[1])
        end
        return 0
      LUA

      # Releases a flight lock only if this token still holds it.
      RELEASE = <<~LUA.freeze
        if redis.call("GET", KEYS[1]) == ARGV[1] then
          return redis.call("DEL", KEYS[1])
        end
        return 0
      LUA

      # lock_ttl: longest a leader may hold a flight — the solve deadline plus
      # a grace (60s + 10s + headroom). poll_interval: how often waiters look
      # for the outcome. outcome_ttl: how long a published outcome is kept
      # for slow waiters.
      def initialize(redis:, namespace: "miniscrap", lock_ttl: 90, poll_interval: 0.1, outcome_ttl: 120)
        @redis = redis
        @namespace = namespace
        @lock_ttl = lock_ttl
        @poll_interval = poll_interval
        @outcome_ttl = outcome_ttl
      end

      def read(key)
        fields = @redis.hgetall(entry_key(key))
        return if fields.empty?

        Entry.new(
          clearance: Codec.load_clearance(fields.fetch("clearance")),
          delta: Float(fields.fetch("delta")),
          challenge: Codec.load_challenge(fields.fetch("challenge"))
        )
      end

      # ttl: seconds the clearance has left (by the store's clock); Redis drops
      # the entry then.
      def write(key, entry, ttl:)
        ms = (ttl * 1000).ceil
        return @redis.del(entry_key(key)) unless ms.positive?

        @redis.multi do |tx|
          tx.hset(entry_key(key), "clearance" => Codec.dump_clearance(entry.clearance),
                                  "delta" => entry.delta.to_s, "challenge" => Codec.dump_challenge(entry.challenge))
          tx.pexpire(entry_key(key), ms)
        end
      end

      def read_failure(key)
        raw = @redis.get(failure_key(key))
        Codec.load_failure(raw) if raw
      end

      # ttl: seconds the failure is remembered; Redis drops it then.
      def write_failure(key, failure, ttl:)
        @redis.set(failure_key(key), Codec.dump_failure(failure), px: (ttl * 1000).ceil)
      end

      def delete_if_current(key, clearance)
        @redis.eval(DELETE_IF_CURRENT, keys: [entry_key(key)], argv: [Codec.dump_clearance(clearance)])
      end

      # Becomes the leader of the key's flight, or nil if one is in flight.
      def lead(key)
        token = SecureRandom.hex(16)
        return unless @redis.set(lock_key(key), token, nx: true, px: (@lock_ttl * 1000).to_i)

        Flight.new(self, key, token, leader: true)
      end

      # The key's in-flight solve to wait on, or nil if there is none.
      def join(key)
        token = @redis.get(lock_key(key))
        Flight.new(self, key, token, leader: false) if token
      end

      # Flight plumbing (public for Flight, not for callers).

      def publish(token, outcome)
        @redis.set(outcome_key(token), JSON.generate(outcome), px: (@outcome_ttl * 1000).to_i)
      end

      def outcome(token)
        raw = @redis.get(outcome_key(token))
        JSON.parse(raw) if raw
      end

      def held?(key, token)
        @redis.get(lock_key(key)) == token
      end

      def release(key, token)
        @redis.eval(RELEASE, keys: [lock_key(key)], argv: [token])
      end

      attr_reader :lock_ttl, :poll_interval

      private

      def entry_key(key)
        "#{@namespace}:clearance:#{id(key)}"
      end

      def lock_key(key)
        "#{@namespace}:flight:#{id(key)}"
      end

      def failure_key(key)
        "#{@namespace}:failure:#{id(key)}"
      end

      def outcome_key(token)
        "#{@namespace}:outcome:#{token}"
      end

      def id(key)
        proxy = key.proxy && Digest::SHA256.hexdigest(key.proxy)[0, 16]
        [key.site_id, key.profile, proxy].map(&:to_s).join(":")
      end

      # One in-flight solve, coordinated through Redis.
      class Flight
        def initialize(backend, key, token, leader:)
          @backend = backend
          @key = key
          @token = token
          @leader = leader
          @published = false
        end

        def fulfill(clearance)
          publish("clearance" => Codec.dump_clearance(clearance))
        end

        def reject(error)
          publish("error" => error.class.name, "message" => error.message)
        end

        # Waits for the leader's outcome — possibly published by another
        # process — and returns its clearance or raises its error.
        def value!
          deadline = monotonic + @backend.lock_ttl + @backend.poll_interval * 2
          loop do
            if (outcome = @backend.outcome(@token))
              return resolve(outcome)
            end
            unless @backend.held?(@key, @token)
              # The leader publishes before releasing, so look once more.
              outcome = @backend.outcome(@token)
              return resolve(outcome) if outcome

              raise SolveFailed, "the solve was abandoned (its leader lost the lock)"
            end
            raise SolveTimeout, "no outcome from the solve's leader within #{@backend.lock_ttl}s" if monotonic > deadline

            sleep @backend.poll_interval
          end
        end

        # Retires the flight. Never leaves waiters without an outcome.
        def finish
          return unless @leader

          reject(SolveFailed.new("the solve was aborted")) unless @published
          @backend.release(@key, @token)
        end

        private

        def publish(outcome)
          return if @published

          @backend.publish(@token, outcome)
          @published = true
        end

        def resolve(outcome)
          return Codec.load_clearance(outcome.fetch("clearance")) if outcome.key?("clearance")

          raise Codec.load_error_class(outcome.fetch("error")).new(outcome.fetch("message"))
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # Stable JSON for the values that cross processes. Clearance JSON is
      # canonical (sorted, nanosecond times) because the compare-and-delete
      # compares it byte for byte.
      module Codec
        module_function

        def dump_clearance(clearance)
          JSON.generate(
            "cookies" => clearance.cookies.to_h.transform_keys(&:to_s).sort.to_h,
            "headers" => clearance.headers.to_h.transform_keys(&:to_s).sort.to_h,
            "ua" => clearance.ua,
            "expires_at" => clearance.expires_at.utc.iso8601(9)
          )
        end

        def load_clearance(json)
          fields = JSON.parse(json)
          Clearance.new(cookies: fields["cookies"], headers: fields["headers"], ua: fields["ua"], expires_at: Time.iso8601(fields["expires_at"]))
        end

        def dump_challenge(challenge)
          JSON.generate("kind" => challenge.kind.to_s, "evidence" => challenge.evidence)
        end

        def load_challenge(json)
          fields = JSON.parse(json)
          Challenge.new(kind: fields["kind"].to_sym, evidence: fields["evidence"].to_h.transform_keys(&:to_sym))
        end

        def dump_failure(failure)
          JSON.generate("error" => failure.error_class.name, "message" => failure.message, "expires_at" => failure.expires_at.utc.iso8601(9))
        end

        def load_failure(json)
          fields = JSON.parse(json)
          Failure.new(error_class: load_error_class(fields["error"]), message: fields["message"], expires_at: Time.iso8601(fields["expires_at"]))
        end

        # The named class when it is a Scraper::Error that takes a message
        # (UnsupportedChallenge never crosses: the registry rejects it before
        # any flight); anything else becomes SolveFailed.
        def load_error_class(name)
          klass = name.to_s.safe_constantize
          klass.is_a?(Class) && klass < Error && klass != UnsupportedChallenge ? klass : SolveFailed
        end
      end
    end
  end
end
