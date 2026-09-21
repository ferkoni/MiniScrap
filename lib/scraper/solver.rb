module Scraper
  # Interface for the slow path: clear a detected challenge and return what the
  # fast path must replay.
  #
  #   solve(url, challenge) -> Clearance
  #
  # A SolverRegistry routes each Challenge to one by its kind. Impls:
  # StubSolver (spec/dev) and FlareSolverrSolver (a real browser, later slice).
  module Solver
    def solve(_url, _challenge)
      raise NotImplementedError, "#{self.class} must implement #solve"
    end
  end
end
