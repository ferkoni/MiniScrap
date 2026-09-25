module Scraper
  # Extracts nissei's (Magento) home page into Sections of product cards: the
  # personalised carousels (fixed aip_* ids) followed by one Section per
  # category showcase, in document order.
  #
  # Every card has the same shape regardless of section: any card can be on
  # sale, so old_price and discount are simply nil when absent. Like
  # NisseiSearchParser, fields are found through layered selectors, and a card
  # without a product link is skipped. A missing carousel is dropped rather
  # than returned empty; if nothing matches, the parse is empty and ScrapeFlow
  # flags the result degraded: "zero_results".
  class NisseiHomeParser
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
    TITLE_SELECTORS = ["a.product-item-link", ".product-item-name a", "a[title]"].freeze
    PRICE_SELECTORS = [".price-wrapper[data-price-type=finalPrice]", "[data-price-type=finalPrice] .price", ".price"].freeze
    OLD_PRICE_SELECTORS = [".price-wrapper[data-price-type=oldPrice]", "[data-price-type=oldPrice] .price", ".old-price .price"].freeze
    DISCOUNT_SELECTORS = [".discount-percent"].freeze
    IMAGE_SELECTORS = ["img.product-image-photo", "img"].freeze
    LABEL_SELECTORS = [".amlabel-text", ".amasty-label-container"].freeze
    ONLINE_ONLY = "Solo Online".freeze
    FREE_DELIVERY = "Delivery Gratis".freeze

    Product = Data.define(:title, :price, :old_price, :discount, :online_only, :free_delivery, :url, :image_url, :position)

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
      products = first_selector_match(section, CARD_SELECTORS).filter_map { |card| extract(card) }
      products = products.each_with_index.map { |fields, index| Product.new(**fields, position: index + 1) }
      Section.new(name: name, title: title, products: products)
    end

    def extract(card)
      link = lazy_first_selector_match(card, TITLE_SELECTORS)
      title = squish(link&.text).presence || link&.[]("title")
      return unless title.present? && link["href"].present?

      labels = first_selector_match(card, LABEL_SELECTORS).map { |node| squish(node.text) }
      {
        title: title,
        price: squish(lazy_first_selector_match(card, PRICE_SELECTORS)&.text),
        old_price: squish(lazy_first_selector_match(card, OLD_PRICE_SELECTORS)&.text),
        discount: squish(lazy_first_selector_match(card, DISCOUNT_SELECTORS)&.text),
        online_only: labels.include?(ONLINE_ONLY),
        free_delivery: labels.include?(FREE_DELIVERY),
        url: link["href"],
        image_url: lazy_first_selector_match(card, IMAGE_SELECTORS)&.[]("src")
      }
    end
  end
end
