module Scraper
  # Raised when a challenge is detected but no solver can handle its kind. In
  # this slice no solver is wired at all, so *any* detected challenge raises it;
  # slice #3 adds a SolverRegistry and only a genuinely unrouted kind raises it.
  # The controller maps it to 501 and echoes `kind` so the caller sees which
  # protection went unhandled.
  class UnsupportedChallenge < Error
    attr_reader :kind

    def initialize(kind)
      @kind = kind
      super("no solver registered for challenge kind #{kind.inspect}")
    end
  end
end
