module Scraper
  # Recognises AWS WAF's silent JavaScript challenge and returns a
  # Challenge(:aws_waf, …); nil for anything it does not recognise.
  #
  # AWS documents an `x-amzn-waf-action` header on challenged responses, but
  # Booking's challenge doesn't send one: it is a 202 with a small page whose
  # script earns an aws-waf-token and reloads. So a 202 carrying a
  # challenge-only body marker counts too. Neither `challenge.js` nor
  # `awsWafCookieDomainList` is a marker: real pages load that script to
  # refresh the token in the background.
  class AwsWafDetector
    include ChallengeDetector

    KIND = :aws_waf
    CHALLENGE_STATUS = 202
    ACTION_HEADER = "x-amzn-waf-action"

    # Present on the challenge page only (checked against real results pages).
    BODY_MARKERS = ['id="challenge-container"', "/__challenge_"].freeze

    def detect(response)
      evidence = evidence_for(response)
      evidence && Challenge.new(kind: KIND, evidence: evidence)
    end

    private

    # The action ("challenge" or "captcha") is recorded, so a visible CAPTCHA
    # shows in the evidence even though it goes through the same solver.
    def evidence_for(response)
      action = header(response, ACTION_HEADER).to_s.strip.downcase
      return { header: ACTION_HEADER, action: action } if action.present?
      return unless response.status == CHALLENGE_STATUS

      marker = BODY_MARKERS.find { |m| response.body.to_s.include?(m) }
      marker && { status: CHALLENGE_STATUS, body: marker }
    end

    # Case-insensitive, as in CloudflareDetector: header casing differs
    # between curl, FlareSolverr and fixtures.
    def header(response, name)
      response.headers.to_h.find { |key, _| key.to_s.casecmp?(name) }&.last
    end
  end
end
