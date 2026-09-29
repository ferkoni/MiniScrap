module Api
  module V1
    # Thin per-site child: a `scrapes` declaration plus one action per endpoint.
    # Each action builds a site-relative path and delegates to the parent's
    # reusable `scrape` helper — no flow wiring, no render logic here.
    class NisseiController < ScrapeController
      # What every product must carry somewhere on a page (Scraper::Coverage):
      # missing on all of them means a selector broke. Sale fields and promo
      # labels are legitimately absent from whole pages, so they aren't here.
      PRODUCT_FIELDS = %w[title url price image_url].freeze

      # A page with products and no filter sidebar at all has lost its filter
      # selectors: one empty group can be real, all three can't.
      SEARCH_CONTRACT = Scraper::Coverage::Contract.new(
        non_empty: %w[results filters],
        required: PRODUCT_FIELDS.map { |field| "results[].#{field}" }
      )

      # Carousels every capture of the endpoint returned with products, so one
      # missing is a break, not a visitor who wasn't shown it (2026-09-29
      # browser captures; not yet confirmed through the fast path).
      GUARANTEED_CAROUSELS = %w[recommended may_like continue_buying gift_ideas best_sellers].freeze

      # Every showcase and every guaranteed carousel must hold products. A
      # failed carousel request shows as follow_up_failed (why) plus one
      # `empty` per guaranteed carousel (what's missing).
      HOME_CONTRACT = Scraper::Coverage::Contract.new(
        non_empty: %w[results results.categories results.categories[].products] +
                   GUARANTEED_CAROUSELS.map { "results.carousels.#{_1}.products" },
        required: PRODUCT_FIELDS.flat_map do |field|
          ["results.categories[].products[].#{field}"] +
            GUARANTEED_CAROUSELS.map { "results.carousels.#{_1}.products[].#{field}" }
        end
      )

      # Both endpoints share this Site, and so one clearance: home never pays
      # its own solve.
      scrapes "nissei",
        base_url: "https://nissei.com/py/",
        profile: :chrome146 # closest to FlareSolverr's Chromium (see FlareSolverrSolver)

      SEARCH_PARSER = Scraper::Nissei::SearchParser.new
      # The home page is carousels and category showcases, not a result list.
      # Two requests to nissei: the page, then the carousels' endpoint.
      HOME_PARSER = Scraper::Nissei::HomeParser.new

      # nissei runs Magento: its search lives at catalogsearch/result.
      def search
        scrape("catalogsearch/result/?q=#{CGI.escape(params[:q].to_s)}", parser: SEARCH_PARSER, contract: SEARCH_CONTRACT)
      end

      def home
        scrape("", parser: HOME_PARSER, contract: HOME_CONTRACT)
      end
    end
  end
end
