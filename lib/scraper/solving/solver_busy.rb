module Scraper
  # Raised when a solve is needed but this process already runs as many as
  # its cap allows (ClearanceStore's max_solves). Failing fast frees the
  # request at once instead of parking it behind solves that can take a
  # minute. Nothing is cached, so a later request tries again. The
  # controller maps it to 503.
  class SolverBusy < Error
    def initialize(msg = "too many solves in progress; try again shortly")
      super
    end
  end
end
