module Scraper
  # What a Clearance is bound to, and the ClearanceStore's cache and
  # single-flight key: the site, the TLS profile and the egress proxy, all
  # filled by ScrapeFlow. `profile` and `proxy` default to nil, so a key built
  # from the site alone still works (specs, a site without a proxy).
  ClearanceKey = Data.define(:site_id, :profile, :proxy) do
    def initialize(site_id:, profile: nil, proxy: nil)
      super
    end
  end
end
