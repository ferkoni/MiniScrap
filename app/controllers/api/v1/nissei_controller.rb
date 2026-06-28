module Api
  module V1
    # Thin per-site child: pure declaration, no scraping logic. The shared
    # `search` action lives on ScrapeController.
    class NisseiController < ScrapeController
      scrapes "nissei",
        base_url: "https://nissei.com/py/",
        profile: :chrome131,
        parser: Scraper::NisseiParser.new,
        search_path: ->(q) { "search?q=#{CGI.escape(q)}" }
    end
  end
end
