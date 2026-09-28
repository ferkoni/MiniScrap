module Scraper
  # What ScrapeFlow#run returns on success; the controller renders it as JSON.
  # `browser_used` + `latency_ms` carry the cold-vs-warm story (a warm fast-path
  # hit is `false` and fast; a browser-solved request is `true` and slow).
  # `filters` is the parser's search filters, nil when the page offers none.
  # `coverage` counts, per JSON path of the output, how many items carry a
  # value; `degraded` is nil when the site's Coverage::Contract holds, else
  # the list of rules that failed (e.g. a field missing on every result: a
  # selector the page no longer matches, surfaced rather than returned as a
  # silent success). See Coverage::Check.
  ScrapeResult = Data.define(:site, :results, :filters, :browser_used, :latency_ms, :coverage, :degraded)
end
