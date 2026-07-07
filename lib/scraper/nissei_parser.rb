module Scraper
  # Extracts product cards from a nissei search page into Results.
  #
  # Selectors are kept as ordered lists (primary first, fallback second) so a
  # small layout shift degrades gracefully. Full layered-selector hardening and
  # the real captured fixture arrive in a later slice; this slice runs against a
  # synthetic fixture.
  class NisseiParser
    include Parser

    CARD_SELECTORS = [".product-item", "li.item.product"].freeze
    TITLE_SELECTORS = [".product-item-link", ".product-item-name a"].freeze
    PRICE_SELECTORS = [".price", ".price-box .price"].freeze
    AVAILABILITY_SELECTORS = [".stock", ".availability"].freeze

    def parse(html)
      doc = Nokogiri::HTML(html)
      cards(doc).each_with_index.map do |card, index|
        link = first_match(card, TITLE_SELECTORS)
        Result.new(
          title: text(link),
          price: text(first_match(card, PRICE_SELECTORS)),
          availability: text(first_match(card, AVAILABILITY_SELECTORS)),
          url: link&.[]("href"),
          position: index + 1
        )
      end
    end

    private

    # The first selector that matches any cards wins; an empty NodeSet otherwise.
    def cards(doc)
      CARD_SELECTORS.each do |selector|
        found = doc.css(selector)
        return found if found.any?
      end
      Nokogiri::XML::NodeSet.new(doc, [])
    end

    def first_match(node, selectors)
      selectors.lazy.filter_map { |selector| node.at_css(selector) }.first
    end

    def text(node)
      node&.text&.strip
    end
  end
end
