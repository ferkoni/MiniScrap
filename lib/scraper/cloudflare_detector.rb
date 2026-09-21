module Scraper
  # Recognises Cloudflare's JS challenge ("Just a moment…") from its markers and
  # returns a Challenge(:cloudflare_js, …); returns nil for anything it does not
  # recognise (e.g. a clean 200). Any one marker is enough — a challenge status,
  # the `cf-mitigated: challenge` header, or a challenge body marker.
  class CloudflareDetector
    include ChallengeDetector

    KIND = :cloudflare_js

    # Cloudflare serves its interstitial with one of these statuses.
    CHALLENGE_STATUSES = [403, 503].freeze

    # Strings present in the challenge interstitial's HTML.
    BODY_MARKERS = ["Just a moment", "cf_chl", "challenge-platform"].freeze

    def detect(response)
      evidence = evidence_for(response)
      return nil unless evidence

      Challenge.new(kind: KIND, evidence: evidence)
    end

    private

    # The first marker that fires, recorded so the Challenge carries *why* it
    # was raised; nil when the Response looks clean.
    def evidence_for(response)
      return { status: response.status } if CHALLENGE_STATUSES.include?(response.status)
      return { header: "cf-mitigated" } if cf_mitigated_challenge?(response)

      marker = BODY_MARKERS.find { |m| response.body.to_s.include?(m) }
      marker ? { body: marker } : nil
    end

    def cf_mitigated_challenge?(response)
      header(response, "cf-mitigated").to_s.strip.casecmp?("challenge")
    end

    # Case-insensitive header lookup — a Response's header casing is not ours to
    # control (curl, FlareSolverr, and test fixtures all differ).
    def header(response, name)
      response.headers.to_h.find { |key, _| key.to_s.casecmp?(name) }&.last
    end
  end
end
