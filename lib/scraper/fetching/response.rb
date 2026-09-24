module Scraper
  # The raw outcome of a fast-path HTTP fetch, before any detection or parsing.
  # Flat, immutable data that travels from a Fetcher into ScrapeFlow.
  Response = Data.define(:status, :headers, :body)
end
