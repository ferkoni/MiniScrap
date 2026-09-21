module Scraper
  class ClearanceStore
    # Keeps entries and in-flight solves in this process's memory: the
    # single-process backend (development, tests, and a one-process deploy).
    # Entries live in a Concurrent::Map; each in-flight solve is a
    # Concurrent::Promises future that waiters block on.
    class MemoryBackend
      def initialize
        @entries = Concurrent::Map.new
        @flights = {}
        @guard = Mutex.new
      end

      def read(key)
        @entries[key]
      end

      # Validity is checked on read against the store's clock, so the ttl is
      # not needed here.
      def write(key, entry, ttl: nil)
        @entries[key] = entry
      end

      # Atomic compare-and-delete.
      def delete_if_current(key, clearance)
        @entries.compute_if_present(key) { |entry| entry unless entry.clearance == clearance }
      end

      # Becomes the leader of the key's flight, or nil if one is in flight.
      def lead(key)
        @guard.synchronize do
          next if @flights.key?(key)

          @flights[key] = Flight.new { @guard.synchronize { @flights.delete(key) } }
        end
      end

      # The key's in-flight solve to wait on, or nil if there is none.
      def join(key)
        @guard.synchronize { @flights[key] }
      end

      # One in-flight solve. The leader resolves it; waiters block in #value!.
      class Flight
        def initialize(&on_finish)
          @future = Concurrent::Promises.resolvable_future
          @on_finish = on_finish
        end

        def fulfill(clearance)
          @future.fulfill(clearance, false)
        end

        def reject(error)
          @future.reject(error, false)
        end

        def value!
          @future.value!
        end

        # Retires the flight so the next miss starts afresh. Never leaves
        # waiters parked on a flight the leader abandoned.
        def finish
          @on_finish.call
          reject(SolveFailed.new("the solve was aborted")) unless @future.resolved?
        end
      end
    end
  end
end
