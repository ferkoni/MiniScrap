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

      # Every section the parser finds must hold products. A carousel that is
      # absent altogether can't be told from one this visitor wasn't shown, so
      # it isn't checked here.
      HOME_CONTRACT = Scraper::Coverage::Contract.new(
        non_empty: %w[results results[].products],
        required: PRODUCT_FIELDS.map { |field| "results[].products[].#{field}" }
      )

      scrapes "nissei",
        base_url: "https://nissei.com/py/",
        profile: :chrome146, # closest to FlareSolverr's Chromium (see FlareSolverrSolver)
        parser: Scraper::Nissei::SearchParser.new,
        contract: SEARCH_CONTRACT

      # nissei runs Magento: its search lives at catalogsearch/result.
      def search
        scrape("catalogsearch/result/?q=#{CGI.escape(params[:q].to_s)}")
      end

      # The home page is carousels and category showcases, not a result list.
      HOME_PARSER = Scraper::Nissei::HomeParser.new

      def home
        scrape("", parser: HOME_PARSER, contract: HOME_CONTRACT)
      end
    end
  end
end
