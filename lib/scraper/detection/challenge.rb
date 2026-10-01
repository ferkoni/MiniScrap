module Scraper
  # A typed anti-bot challenge that a ChallengeDetector identifies on a Response.
  # `kind` names the protection so solving can be routed (:cloudflare_js and
  # :aws_waf are produced today; others name future detectors). `evidence`
  # records what tripped detection (a status, a header, or a body marker) for
  # logging and debugging. Detection returns this typed value, never a boolean —
  # so the flow knows *what* it hit, not merely *that* it hit something.
  Challenge = Data.define(:kind, :evidence)
end
