module Scraper
  # Base class for the flow-level errors that ScrapeFlow raises and the
  # controller maps to HTTP status codes. Failures are *raised*, never returned:
  # the core stays output-medium-agnostic and the edge owns the status mapping.
  # Subclasses arrive with their slices — UnsupportedChallenge here; SolveFailed,
  # RetryBudgetExhausted, and SolveTimeout with the solve/retry slices.
  class Error < StandardError; end
end
