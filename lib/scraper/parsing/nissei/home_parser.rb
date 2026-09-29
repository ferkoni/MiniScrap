require "json"
require "uri"

module Scraper
  module Nissei
    # Extracts nissei's (Magento) home page into a Home: the personalised
    # carousels, keyed by a fixed name, and the category showcases, in page
    # order.
    #
    # The carousels aren't in the server HTML: the page's script loads them
    # from nissei's aipersonalization endpoint, so the parser declares that
    # request as a FollowUp and reads the carousels from its JSON. Every known
    # carousel is always a key, nil when the JSON lacks it or the request
    # failed, so the shape never changes. The showcases come from the page
    # HTML, each with the URL of the category page its heading links to, its
    # one identifier that isn't page text.
    #
    # Cards are read by CardExtractor, the same as on search, so every
    # Product has one shape. A missing guaranteed carousel, a showcase with
    # no products or no showcases at all are flagged by the home
    # Coverage::Contract.
    class HomeParser
      include Parser

      # Home's key => the endpoint's section id. Other ids (continue_browsing,
      # which follows whichever visitor triggered nissei's cached render, or
      # anything new) are ignored.
      CAROUSELS = {
        "recommended" => "ofertas_recomendadas",
        "may_like" => "you_may_like",
        "continue_buying" => "continua_comprando",
        "gift_ideas" => "gift_ideas",
        "best_sellers" => "bestsellers"
      }.freeze

      # The request nissei's personalization.js makes, as the browser sends
      # it. `sections` is copied verbatim: the endpoint returns every section
      # regardless. `_` is jQuery's cache-buster, sent so the request looks
      # like the browser's.
      SECTIONS_PATH = "aipersonalization/ajax/sections?context=home" \
                      "&sections=%5B%22ofertas_recomendadas%22%2C%22continue_browsing%22%2C%22you_may_like%22%5D" \
                      "&currency=PYG".freeze
      SECTIONS_HEADERS = { "X-Requested-With" => "XMLHttpRequest" }.freeze

      # The parser doesn't know its Site; category hrefs are either absolute
      # or /py/-relative, resolved against this.
      BASE_URL = "https://nissei.com".freeze

      CATEGORY_SELECTORS = [".block-main-product"].freeze
      CATEGORY_TITLE_SELECTORS = ["h2.title", ".block-title", "h2"].freeze
      CATEGORY_LINK_SELECTORS = ["h2.title a[href]", ".block-title a[href]", "h2 a[href]"].freeze
      CARD_SELECTORS = [".product-item-info", "li.product-item"].freeze
      CARD_EXTRACTOR = CardExtractor.new

      # `fallback` is the section's is_fallback, passed through until its
      # meaning is confirmed. to_h goes deep so the API can serialize it.
      Carousel = Data.define(:title, :fallback, :products) do
        def to_h
          super.merge(products: products.map(&:to_h))
        end
      end

      Category = Data.define(:title, :url, :products) do
        def to_h
          super.merge(products: products.map(&:to_h))
        end
      end

      # `carousels` holds every CAROUSELS key, nil for an absent carousel.
      Home = Data.define(:carousels, :categories) do
        def to_h
          { carousels: carousels.transform_values { _1&.to_h }, categories: categories.map(&:to_h) }
        end
      end

      def follow_ups
        [FollowUp.new(name: :carousels, path: "#{SECTIONS_PATH}&_=#{now_ms}", headers: SECTIONS_HEADERS)]
      end

      def parse(html)
        parse_page(html).results
      end

      def parse_page(html, follow_ups: {})
        home = Home.new(carousels: carousels(follow_ups[:carousels]), categories: categories(Nokogiri::HTML5(html)))
        ParsedPage.new(results: home, filters: nil)
      end

      private

      # Every key, in CAROUSELS order: nil for a section the JSON lacks, and
      # all nil when the body is missing (the request failed) or isn't JSON.
      def carousels(json)
        sections = sections_by_id(json)
        CAROUSELS.transform_values { |id| sections[id] && build_carousel(sections[id]) }
      end

      def sections_by_id(json)
        sections = JSON.parse(json.to_s)["sections"] if json
        Array(sections).select { _1.is_a?(Hash) }.to_h { [_1["id"], _1] }
      rescue JSON::ParserError, TypeError, NoMethodError
        {}
      end

      # A section with no cards is a Carousel with no products: the coverage
      # check's to flag, not the parser's to hide.
      def build_carousel(section)
        fragment = Nokogiri::HTML5.fragment(section["html"].to_s)
        Carousel.new(
          title: squish(section["title"]),
          fallback: section["is_fallback"],
          products: CARD_EXTRACTOR.products(first_selector_match(fragment, CARD_SELECTORS))
        )
      end

      def categories(doc)
        first_selector_match(doc, CATEGORY_SELECTORS).map do |section|
          Category.new(
            title: squish(lazy_first_selector_match(section, CATEGORY_TITLE_SELECTORS)&.text),
            url: category_url(section),
            products: CARD_EXTRACTOR.products(first_selector_match(section, CARD_SELECTORS))
          )
        end
      end

      # Absolute, from either link form; nil for a heading without a link or
      # with an unparsable href.
      def category_url(section)
        href = lazy_first_selector_match(section, CATEGORY_LINK_SELECTORS)&.[]("href")
        href && URI.join(BASE_URL, href.strip).to_s
      rescue URI::Error
        nil
      end

      def now_ms
        (Time.now.to_f * 1000).to_i
      end
    end
  end
end
