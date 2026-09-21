module Scraper
  # Raised when a challenge is detected but no solver can handle its kind — the
  # SolverRegistry has no entry for it.
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
