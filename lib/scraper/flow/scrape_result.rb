module Scraper
  # What ScrapeFlow#run returns on success; the controller renders it as JSON.
  # `browser_used` + `latency_ms` carry the cold-vs-warm story (a warm fast-path
  # hit is `false` and fast; a browser-solved request is `true` and slow).
  # `degraded` is nil on a clean parse and "zero_results" when a non-challenge
  # 200 parsed to zero products (a post-parse structural anomaly, surfaced
  # distinctly rather than as a silent empty success).
  ScrapeResult = Data.define(:site, :results, :browser_used, :latency_ms, :degraded)
end
