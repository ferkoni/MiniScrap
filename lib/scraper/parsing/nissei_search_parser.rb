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
  class NisseiSearchParser
    include Parser

    # The main result listing first: a bare .product-item also matches the
    # wishlist sidebar's template.
    CARD_SELECTORS = [".products.wrapper li.product-item", "ol.products li.product-item", "li.item.product"].freeze
    TITLE_SELECTORS = ["a.product-item-link", ".product-item-name a", "a[title]"].freeze
    PRICE_SELECTORS = ["[data-price-type=finalPrice] .price", ".price-box .price", ".price"].freeze
    ONLINE_AND_DELIVERY_SELECTORS = [".amlabel-text", ".amasty-label-container"].freeze
    ONLINE_ONLY = "Solo Online".freeze
    FREE_DELIVERY = "Delivery Gratis".freeze

    Result = Data.define(:title, :price, :online_only, :free_delivery, :url, :position)

    def parse(html)
      products = cards(Nokogiri::HTML5(html)).filter_map { |card| extract(card) }
      products.each_with_index.map { |fields, index| Result.new(**fields, position: index + 1) }
    end

    private

    def extract(card)
      link = lazy_first_selector_match(card, TITLE_SELECTORS)
      title = squish(link&.text).presence || link&.[]("title")
      return unless title.present? && link["href"].present?

      {
        title: title,
        price: squish(lazy_first_selector_match(card, PRICE_SELECTORS)&.text),
        online_only:  online_only(card),
        free_delivery: free_delivery(card),
        url: link["href"]
      }
    end

    def online_only(card)
      nodes = first_selector_match(card, ONLINE_AND_DELIVERY_SELECTORS)
      nodes.map { |n| squish(n.text) }.join.include?(ONLINE_ONLY)
    end

    def free_delivery(card)
      nodes = first_selector_match(card, ONLINE_AND_DELIVERY_SELECTORS)
      nodes.map { |n| squish(n.text) }.join.include?(FREE_DELIVERY)
    end

    # The first selector that matches any cards wins; an empty NodeSet otherwise.
    def cards(doc)
      CARD_SELECTORS.each do |selector|
        found = doc.css(selector)
        return found if found.any?
      end
      Nokogiri::XML::NodeSet.new(doc, [])
    end
  end
end
