module Scraper
  # Raised when the fast path produced no HTTP response at all — DNS, TLS, or
  # connection failure, or the transfer ran past its deadline and was killed.
  # (A challenge or any other HTTP status is a Response, never this.) The
  # controller maps it to 502.
  class FetchFailed < Error; end
end
