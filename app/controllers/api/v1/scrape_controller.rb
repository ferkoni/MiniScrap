module Api
  module V1
    # Abstract parent: the only Rails-aware part of the scraping path. It owns
    # the `scrapes` class-level DSL (declares the one Site, stored at boot) and
    # the reusable `scrape(path)` helper — build a ScrapeFlow for a
    # controller-built path, run it, render the returned ScrapeResult as JSON.
    # Per-site children declare their Site and add one action per endpoint.
    class ScrapeController < ApplicationController
      class_attribute :site, instance_accessor: false

      # Class-level DSL: declares the one Site this controller scrapes.
      def self.scrapes(id, base_url:, profile:, parser:)
        self.site = Scraper::Site.new(
          id:       id,
          base_url: base_url,
          profile:  profile,
          parser:   parser
        )
      end

      private

      # Reusable edge helper: run the flow for a controller-built, site-relative
      # path and render the result. Exception -> HTTP status mapping arrives with
      # the error slices (#2/#3/#4).
      def scrape(path)
        result = Scraper::ScrapeFlow.new(site: self.class.site, fetcher: fetcher).run(path)
        render json: serialize(result)
      end

      # Overridable wiring hook. The slice-1 walking skeleton defaults to a
      # demoable FakeFetcher; slice #5 swaps this for the real
      # Scraper::CurlImpersonateFetcher in production wiring.
      def fetcher
        Scraper::FakeFetcher.new
      end

      def serialize(result)
        {
          site:         result.site,
          results:      result.results.map(&:to_h),
          browser_used: result.browser_used,
          latency_ms:   result.latency_ms,
          degraded:     result.degraded
        }
      end
    end
  end
end
