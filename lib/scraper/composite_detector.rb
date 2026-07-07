module Scraper
  # Runs an ordered list of ChallengeDetectors and returns the first hit, so
  # detectors compose without anyone editing the flow. The controller builds the
  # list from its overridable `detectors` hook; adding a protection is a new
  # detector in that list, not a change here or in ScrapeFlow.
  class CompositeDetector
    include ChallengeDetector

    def initialize(detectors)
      @detectors = detectors
    end

    def detect(response)
      @detectors.each do |detector|
        challenge = detector.detect(response)
        return challenge if challenge
      end
      nil
    end
  end
end
