module Scraper
  # Raised when a solve did not produce a usable clearance — the solver errored,
  # its service was unreachable, or it returned with the challenge still in
  # place. Under single-flight every caller waiting on that solve raises it
  # too. The controller maps it to 502.
  class SolveFailed < Error
    def initialize(msg = "the solver did not produce a clearance")
      super
    end
  end
end
