module Scraper
  # Raised when a solve exceeded its deadline, instead of blocking the request
  # indefinitely. The controller maps it to 504.
  class SolveTimeout < Error
    def initialize(msg = "the solve exceeded its deadline")
      super
    end
  end
end
