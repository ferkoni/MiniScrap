require "uri"

module Scraper
  # Immutable bundle of one target's config: id, base URL, curl-impersonate
  # profile, and its Parser. Built once (at class load) by a per-site controller
  # via the `scrapes` DSL and injected into ScrapeFlow, which stays site-agnostic.
  Site = Data.define(:id, :base_url, :profile, :parser) do
    # Join a controller-built, site-relative path onto base_url, e.g.
    # url_for("search?q=ps5") -> "https://nissei.com/py/search?q=ps5".
    #
    # Paths are fixed config or built from typed params by the controller. If an
    # open, client-supplied path is ever accepted, add a same-host guard:
    # URI.join can escape the host on a leading "/" or "//evil.com".
    def url_for(path)
      URI.join(base_url, path).to_s
    end
  end
end
