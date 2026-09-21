module Scraper
  # Raised when the fast path is still challenged after the flow has spent its
  # retry budget on solves — a site that keeps challenging produces an honest
  # error instead of an endless browser loop. The controller maps it to 502.
  class RetryBudgetExhausted < Error
    def initialize(msg = "still challenged after exhausting the retry budget")
      super
    end
  end
end
