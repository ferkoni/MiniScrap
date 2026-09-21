module Scraper
  # Base class for the flow-level errors that ScrapeFlow raises and the
  # controller maps to HTTP status codes. Failures are *raised*, never returned:
  # the core stays output-medium-agnostic and the edge owns the status mapping.
  # Subclasses: UnsupportedChallenge, RetryBudgetExhausted, SolveFailed,
  # SolveTimeout.
  class Error < StandardError; end
end
