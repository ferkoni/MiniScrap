module Scraper
  # Interface for challenge detection:
  #
  #   detect(Response) -> Challenge | nil
  #
  # Returns a typed Challenge naming the protection it recognises, or nil when
  # the Response looks clean. Implementations identify *which* protection so the
  # flow can route solving; CompositeDetector runs an ordered list of them.
  module ChallengeDetector
    def detect(_response)
      raise NotImplementedError, "#{self.class} must implement #detect"
    end
  end
end
