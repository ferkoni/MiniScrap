module Scraper
  # Routes a Challenge to the Solver registered for its kind. Adding a
  # protection is one entry here plus its detector — never an edit to
  # ScrapeFlow. A kind with no entry raises UnsupportedChallenge, so an
  # unrecognised protection fails honestly instead of silently.
  class SolverRegistry
    def initialize(solvers_by_kind = {})
      @solvers = solvers_by_kind
    end

    def for(challenge)
      @solvers.fetch(challenge.kind) { raise UnsupportedChallenge, challenge.kind }
    end
  end
end
