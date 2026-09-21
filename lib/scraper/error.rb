module Scraper
  # Base class for the flow-level errors that ScrapeFlow raises and the
  # controller maps to HTTP status codes. Failures are *raised*, never returned:
  # the core stays output-medium-agnostic and the edge owns the status mapping.
  # Subclasses arrive with their slices — UnsupportedChallenge and
  # RetryBudgetExhausted so far; SolveFailed and SolveTimeout with the
  # single-flight and FlareSolverr slices.
  class Error < StandardError; end
end
