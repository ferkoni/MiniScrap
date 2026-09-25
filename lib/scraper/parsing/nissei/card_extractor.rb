module Scraper
  module Nissei
    # Reads nissei (Magento) product cards into Products. Search results and
    # every home section render the same card markup, so both parsers share
    # this. Fields come through layered selectors, primary first; a card
    # without a title and link is not a product (e.g. the wishlist sidebar's
    # Knockout template) and is skipped. Sale fields are nil when a card is
    # not on sale.
    class CardExtractor
      include Parser

      TITLE_SELECTORS = ["a.product-item-link", ".product-item-name a", "a[title]"].freeze
      PRICE_SELECTORS = [".price-wrapper[data-price-type=finalPrice]", "[data-price-type=finalPrice] .price", ".price-box .price", ".price"].freeze
      OLD_PRICE_SELECTORS = [".price-wrapper[data-price-type=oldPrice]", "[data-price-type=oldPrice] .price", ".old-price .price"].freeze
      DISCOUNT_SELECTORS = [".discount-percent"].freeze
      IMAGE_SELECTORS = ["img.product-image-photo", "img"].freeze
      LABEL_SELECTORS = [".amlabel-text", ".amasty-label-container"].freeze
      ONLINE_ONLY = "Solo Online".freeze
      FREE_DELIVERY = "Delivery Gratis".freeze

      Product = Data.define(:title, :price, :old_price, :discount, :online_only, :free_delivery, :url, :image_url, :position)

      # Cards -> Products numbered 1-based in document order, non-products skipped.
      def products(cards)
        cards.filter_map { |card| fields(card) }
          .each_with_index.map { |fields, index| Product.new(**fields, position: index + 1) }
      end

      private

      def fields(card)
        link = lazy_first_selector_match(card, TITLE_SELECTORS)
        title = squish(link&.text).presence || link&.[]("title")
        return unless title.present? && link["href"].present?

        # Matched whole, so a label merely containing the text doesn't count.
        labels = first_selector_match(card, LABEL_SELECTORS).map { |node| squish(node.text) }
        {
          title: title,
          price: text(card, PRICE_SELECTORS),
          old_price: text(card, OLD_PRICE_SELECTORS),
          discount: text(card, DISCOUNT_SELECTORS),
          online_only: labels.include?(ONLINE_ONLY),
          free_delivery: labels.include?(FREE_DELIVERY),
          url: link["href"],
          image_url: lazy_first_selector_match(card, IMAGE_SELECTORS)&.[]("src")
        }
      end

      def text(card, selectors)
        squish(lazy_first_selector_match(card, selectors)&.text)
      end
    end
  end
end
