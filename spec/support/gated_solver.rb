# A Solver that blocks inside #solve until the spec releases it, so concurrency
# specs can pile callers up behind an in-flight solve and assert deterministically
# how many solves ran. Each solve takes the next outcome (the last repeats): a
# callable returning a Clearance, or raising to simulate a failed solve.
class GatedSolver
  include Scraper::Solver

  WAIT = 2 # seconds; a spec that waits longer than this has deadlocked

  def initialize(*outcomes)
    @outcomes = outcomes
    @calls = Concurrent::AtomicFixnum.new
    @entered = Queue.new
    @gate = Queue.new
  end

  def calls
    @calls.value
  end

  def solve(_url, _challenge, proxy: nil)
    @calls.increment
    @entered << true
    raise "GatedSolver was never released" if @gate.pop(timeout: WAIT).nil?

    (@outcomes.size > 1 ? @outcomes.shift : @outcomes.first).call
  end

  # Blocks until a solve has started; false if none did within WAIT.
  def wait_until_entered
    !@entered.pop(timeout: WAIT).nil?
  end

  # Lets `count` blocked solves finish.
  def release(count = 1)
    count.times { @gate << true }
  end

  # Waits until every thread is parked (blocked on the gate, the flight, or the
  # store's guard), so a spec releases the solve only once the herd has piled up.
  def self.wait_until_blocked(threads)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT
    until threads.all? { |thread| thread.status == "sleep" }
      raise "threads never blocked" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end
end
