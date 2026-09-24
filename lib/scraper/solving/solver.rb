module Scraper
  # Interface for the slow path: clear a detected challenge and return what the
  # fast path must replay.
  #
  #   solve(url, challenge, proxy:) -> Clearance
  #
  # `proxy` is the egress the clearance must be solved through (nil: none) —
  # the clearance is bound to the IP that solved it.
  #
  # A SolverRegistry routes each Challenge to one by its kind. Impls:
  # StubSolver (spec/dev) and FlareSolverrSolver (a real browser, later slice).
  module Solver
    def solve(_url, _challenge, proxy: nil)
      raise NotImplementedError, "#{self.class} must implement #solve"
    end
  end
end
