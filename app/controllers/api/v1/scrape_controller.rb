module Api
  module V1
    # Abstract parent: the only Rails-aware part of the scraping path. It owns
    # the shared `search` action — build a ScrapeFlow, run it, render the
    # returned ScrapeResult as JSON. Per-site children declare their Site via
    # the `scrapes` DSL and add nothing else.
    class ScrapeController < ApplicationController
      class_attribute :site, instance_accessor: false

      # Class-level DSL: declares the one Site this controller scrapes.
      def self.scrapes(id, base_url:, profile:, parser:, search_path:)
        self.site = Scraper::Site.new(
          id:          id,
          base_url:    base_url,
          profile:     profile,
          parser:      parser,
          search_path: search_path
        )
      end

      def search
        flow   = Scraper::ScrapeFlow.new(site: self.class.site, fetcher: fetcher)
        result = flow.run(params[:q].to_s)
        render json: serialize(result)
      end

      private

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
          latency_ms:   result.latency_ms
        }
      end
    end
  end
end
