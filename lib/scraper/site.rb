require "uri"

module Scraper
  # Immutable bundle of one target's configuration: its id, base URL, the
  # curl-impersonate profile, its Parser, and a callable that builds the
  # search path from a query. Built by a per-site controller via the `scrapes`
  # DSL and injected into ScrapeFlow, which stays site-agnostic.
  Site = Data.define(:id, :base_url, :profile, :parser, :search_path) do
    # Absolute URL for a search query, e.g. "https://nissei.com/py/search?q=ps5".
    def search_url(query)
      URI.join(base_url, search_path.call(query)).to_s
    end
  end
end
