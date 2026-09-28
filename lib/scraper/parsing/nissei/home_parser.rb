module Scraper
  module Nissei
    # Extracts nissei's (Magento) home page into Sections of product cards: the
    # personalised carousels (fixed aip_* ids) followed by one Section per
    # category showcase, in document order.
    #
    # Cards are read by CardExtractor, the same as on search, so every
    # section's Products have one shape. A missing carousel is dropped rather
    # than returned empty. An empty parse, or a section left with no products,
    # is flagged by the home Coverage::Contract.
    class HomeParser
      include Parser

      CAROUSELS = {
        "recommended" => "#aip_ofertas_recomendadas",
        "may_like" => "#aip_you_may_like",
        "continue_buying" => "#aip_continua_comprando",
        "gift_ideas" => "#aip_gift_ideas",
        "best_sellers" => "#aip_bestsellers"
      }.freeze
      CATEGORY = "category".freeze

      CATEGORY_SELECTORS = [".block-main-product"].freeze
      SECTION_TITLE_SELECTORS = ["h2.title", ".block-title", "h2"].freeze
      CARD_SELECTORS = [".product-item-info", "li.product-item"].freeze
      CARD_EXTRACTOR = CardExtractor.new

      # `name` is a stable key ("recommended", …, or "category"); `title` is the
      # heading the page shows. to_h goes deep so the API can serialize it.
      Section = Data.define(:name, :title, :products) do
        def to_h
          super.merge(products: products.map(&:to_h))
        end
      end

      def parse(html)
        doc = Nokogiri::HTML5(html)
        carousels(doc) + categories(doc)
      end

      private

      def carousels(doc)
        CAROUSELS.filter_map do |name, selector|
          section = doc.at_css(selector)
          section && build_section(name, section)
        end
      end

      def categories(doc)
        first_selector_match(doc, CATEGORY_SELECTORS).map { |section| build_section(CATEGORY, section) }
      end

      def build_section(name, section)
        title = squish(lazy_first_selector_match(section, SECTION_TITLE_SELECTORS)&.text)
        products = CARD_EXTRACTOR.products(first_selector_match(section, CARD_SELECTORS))
        Section.new(name: name, title: title, products: products)
      end
    end
  end
end
