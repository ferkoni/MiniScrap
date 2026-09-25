module Scraper
  module Nissei
    # Extracts a nissei (Magento) search results page: its product cards, read
    # by CardExtractor into Products with a clean, source-agnostic shape.
    #
    # Everything is found through layered selectors — an ordered list, primary
    # first, broader fallbacks after — so a layout shift degrades gracefully
    # instead of returning nothing. If every card selector misses, the parse is
    # empty and ScrapeFlow flags the result degraded: "zero_results".
    #
    # parse_page also reads the sidebar's filter block (Amasty's layered
    # navigation) into Filters: the category tree, brands and colors, each
    # option with the id nissei filters by and the URL that applies it. A page
    # without the block yields empty Filters, never nil, so search always
    # returns the same shape.
    class SearchParser
      include Parser

      # The main result listing first: a bare .product-item also matches the
      # wishlist sidebar's template.
      CARD_SELECTORS = [".products.wrapper li.product-item", "ol.products li.product-item", "li.item.product"].freeze
      CARD_EXTRACTOR = CardExtractor.new

      # Each group is found by the attribute Amasty keys it on, then by its
      # item-list class.
      FILTER_BLOCK_SELECTORS = [".filter-content", "#narrow-by-list"].freeze
      CATEGORY_GROUP_SELECTORS = ["form[data-amshopby-filter=category_ids] > ul", "ul.am-filter-items-category_ids"].freeze
      BRAND_ITEM_SELECTORS = ["form[data-amshopby-filter=marca] li.item", ".am-filter-items-marca li.item"].freeze
      COLOR_ITEM_SELECTORS = ["form[data-amshopby-filter=color] .am-swatch-wrapper", ".am-filter-items-color .item"].freeze

      # `value` is the id nissei filters by (e.g. ?marca=1598); `url` applies it.
      FilterOption = Data.define(:label, :value, :url)

      # A category option and its subcategories, to any depth.
      CategoryOption = Data.define(:label, :value, :url, :children) do
        def to_h
          super.merge(children: children.map(&:to_h))
        end
      end

      Filters = Data.define(:categories, :brands, :colors) do
        def to_h
          { categories: categories.map(&:to_h), brands: brands.map(&:to_h), colors: colors.map(&:to_h) }
        end
      end

      def parse(html)
        products(Nokogiri::HTML5(html))
      end

      def parse_page(html)
        doc = Nokogiri::HTML5(html)
        ParsedPage.new(results: products(doc), filters: filters(doc))
      end

      private

      def products(doc)
        CARD_EXTRACTOR.products(first_selector_match(doc, CARD_SELECTORS))
      end

      def filters(doc)
        block = lazy_first_selector_match(doc, FILTER_BLOCK_SELECTORS)
        return Filters.new(categories: [], brands: [], colors: []) unless block

        Filters.new(
          categories: category_options(lazy_first_selector_match(block, CATEGORY_GROUP_SELECTORS)),
          brands: first_selector_match(block, BRAND_ITEM_SELECTORS).filter_map { |item| filter_option(item) },
          colors: first_selector_match(block, COLOR_ITEM_SELECTORS).filter_map { |item| filter_option(item) }
        )
      end

      # Walks one level of the category tree: the list's own <li>s, each
      # recursing into its nested .items-children list.
      def category_options(list)
        return [] unless list

        list.css("> li").filter_map do |item|
          option = filter_option(item)
          option && CategoryOption.new(**option.to_h, children: category_options(item.at_css("> ul")))
        end
      end

      # Reads an item's own link and input — never a nested category's.
      def filter_option(item)
        link = item.at_css("> a")
        label = squish(item["data-label"].presence || link&.[]("data-label").presence || link&.text)
        return unless label.present? && link&.[]("href").present?

        FilterOption.new(label: label, value: item.at_css("> input")&.[]("value"), url: link["href"])
      end
    end
  end
end
