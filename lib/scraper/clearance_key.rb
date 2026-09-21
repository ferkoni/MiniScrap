module Scraper
  # What a Clearance is bound to, and the ClearanceStore's cache (and later
  # single-flight) key. Ships keyed by `site_id` alone; the `profile`/`proxy`
  # slots exist so proxy rotation can refine the key without touching callers.
  ClearanceKey = Data.define(:site_id, :profile, :proxy) do
    def initialize(site_id:, profile: nil, proxy: nil)
      super
    end
  end
end
