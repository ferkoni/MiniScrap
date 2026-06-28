require "uri"

module Scraper
  # Immutable bundle of one target's configuration: its id, base URL, the
  # curl-impersonate profile, its Parser, and a callable that builds the
  # search path from a query. Built by a per-site controller via the `scrapes`
  # DSL and injected into ScrapeFlow, which stays site-agnostic.
  Site = Data.define(:id, :base_url, :profile, :parser, :search_path) do
    # Absolute URL for a search query, e.g. "https://nissei.com/py/search?q=ps5".
    # The base is forced to end in "/" so URI.join treats it as a directory and
    # appends the search path, rather than replacing the last path segment — a
    # base_url without a trailing slash would otherwise silently drop it.
    def search_url(query)
      base = base_url.end_with?("/") ? base_url : "#{base_url}/"
      URI.join(base, search_path.call(query)).to_s
    end
  end
end
