module Api
  module V1
    # Thin per-site child: a `scrapes` declaration plus one action per endpoint.
    # Each action builds a site-relative path and delegates to the parent's
    # reusable `scrape` helper — no flow wiring, no render logic here.
    class NisseiController < ScrapeController
      scrapes "nissei",
        base_url: "https://nissei.com/py/",
        profile: :chrome146, # closest to FlareSolverr's Chromium (see FlareSolverrSolver)
        parser: Scraper::NisseiParser.new

      # nissei runs Magento: its search lives at catalogsearch/result.
      def search
        scrape("catalogsearch/result/?q=#{CGI.escape(params[:q].to_s)}")
      end
    end
  end
end
