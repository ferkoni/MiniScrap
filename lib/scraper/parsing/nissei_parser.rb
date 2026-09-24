module Scraper
  # Extracts product cards from a nissei (Magento) search results page into
  # Results with a clean, source-agnostic shape.
  #
  # Every field is found through layered selectors — an ordered list, primary
  # first, broader fallbacks after — so a layout shift degrades gracefully
  # instead of returning nothing. A card without a product link (e.g. the
  # wishlist sidebar's Knockout template, which shares the .product-item class)
  # is not a product and is skipped. If every card selector misses, the parse
  # is empty and ScrapeFlow flags the result degraded: "zero_results".
  class NisseiParser
    include Parser

    # The main result listing first: a bare .product-item also matches the
    # wishlist sidebar's template.
    CARD_SELECTORS = [".products.wrapper li.product-item", "ol.products li.product-item", "li.item.product"].freeze
    TITLE_SELECTORS = ["a.product-item-link", ".product-item-name a", "a[title]"].freeze
    PRICE_SELECTORS = ["[data-price-type=finalPrice] .price", ".price-box .price", ".price"].freeze

    # nissei cards carry no stock text: an in-stock card has an add-to-cart
    # form, while Magento marks an out-of-stock one with .stock.unavailable.
    OUT_OF_STOCK_SELECTORS = [".stock.unavailable", ".out-of-stock"].freeze
    IN_STOCK_SELECTORS = ["form[data-role=tocart-form]", "button.tocart", ".stock.available"].freeze

    def parse(html)
      products = cards(Nokogiri::HTML(html)).filter_map { |card| extract(card) }
      products.each_with_index.map { |fields, index| Result.new(**fields, position: index + 1) }
    end

    private

    def extract(card)
      link = first_match(card, TITLE_SELECTORS)
      title = squish(link&.text).presence || link&.[]("title")
      return unless title.present? && link["href"].present?

      {
        title: title,
        price: squish(first_match(card, PRICE_SELECTORS)&.text),
        availability: availability(card),
        url: link["href"]
      }
    end

    # The first selector that matches any cards wins; an empty NodeSet otherwise.
    def cards(doc)
      CARD_SELECTORS.each do |selector|
        found = doc.css(selector)
        return found if found.any?
      end
      Nokogiri::XML::NodeSet.new(doc, [])
    end

    def availability(card)
      return "out_of_stock" if first_match(card, OUT_OF_STOCK_SELECTORS)
      return "in_stock" if first_match(card, IN_STOCK_SELECTORS)

      nil
    end

    def first_match(node, selectors)
      selectors.lazy.filter_map { |selector| node.at_css(selector) }.first
    end

    # Collapses runs of whitespace — including the non-breaking space nissei
    # puts after "Gs." — into single spaces.
    def squish(text)
      text&.gsub(/[[:space:]]+/, " ")&.strip
    end
  end
end
