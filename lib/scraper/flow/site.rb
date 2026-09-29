require "uri"

module Scraper
  # Immutable bundle of one target's identity: id, base URL and
  # curl-impersonate profile, which together with the proxy are what a
  # clearance is bound to (see ClearanceKey). Every endpoint of a site shares
  # it, and so shares one clearance. How a page is read (its Parser and
  # Coverage::Contract) belongs to the endpoint, not the site. Built once (at
  # class load) by a per-site controller via the `scrapes` DSL and injected
  # into ScrapeFlow, which stays site-agnostic.
  Site = Data.define(:id, :base_url, :profile) do
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
