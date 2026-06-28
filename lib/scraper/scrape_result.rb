module Scraper
  # What ScrapeFlow#run returns on success; the controller renders it as JSON.
  # `browser_used` + `latency_ms` carry the cold-vs-warm story (a warm fast-path
  # hit is `false` and fast; a browser-solved request is `true` and slow).
  ScrapeResult = Data.define(:site, :results, :browser_used, :latency_ms)
end
