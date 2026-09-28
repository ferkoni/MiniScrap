module Scraper
  module Booking
    # Extracts a Booking.com search results page (server-rendered HTML) into
    # Properties with a clean, source-agnostic shape. Text stays as the page
    # shows it ("9,1", "US$1.330"); only `stars` is a count, because the page
    # draws icons rather than text.
    #
    # Booking's class names are generated hashes, so its data-testid hooks are
    # the primary selectors, with structural fallbacks (ARIA roles, the title's
    # <h3>) after them. A card without a title and link is skipped. If every
    # card selector misses, the parse is empty and ScrapeFlow flags the result
    # degraded: "zero_results".
    #
    # `offset` is the index of the first card on this page, so positions stay
    # absolute across pages: with offset 25, the first card is position 26.
    class SearchParser
      include Parser

      CARD_SELECTORS = ["[data-testid=property-card]", "[role=list] > [role=listitem][aria-label]"].freeze
      LINK_SELECTORS = ["a[data-testid=title-link]", "h3 a[href]"].freeze
      TITLE_SELECTORS = ["[data-testid=title]"].freeze
      ADDRESS_SELECTORS = ["[data-testid=address-link]", "[data-testid=address]"].freeze
      DISTANCE_SELECTORS = ["[data-testid=distance]"].freeze
      REVIEW_SELECTORS = ["[data-testid=review-score]"].freeze
      PRICE_SELECTORS = ["[data-testid=price-and-discounted-price]"].freeze
      TAXES_SELECTORS = ["[data-testid=taxes-and-charges]"].freeze
      STAY_SELECTORS = ["[data-testid=price-for-x-nights]"].freeze
      IMAGE_SELECTORS = ["img[data-testid=image]", "img[src]"].freeze

      # Official stars and Booking's own "squares" rating are drawn alike;
      # stars_kind says which one the count is.
      STAR_KINDS = {
        "[data-testid=rating-stars]" => "official",
        "[data-testid=rating-squares]" => "booking_rating"
      }.freeze

      Property = Data.define(
        :name, :url, :address, :distance,
        :review_score, :review_label, :review_count,
        :stars, :stars_kind,
        :price, :taxes_note, :stay,
        :image_url, :position
      )

      def initialize(offset: 0)
        @offset = offset
      end

      def parse(html)
        cards = first_selector_match(Nokogiri::HTML5(html), CARD_SELECTORS)
        cards.filter_map { |card| extract(card) }
          .each_with_index.map { |fields, index| Property.new(**fields, position: @offset + index + 1) }
      end

      private

      def extract(card)
        link = lazy_first_selector_match(card, LINK_SELECTORS)
        name = text(card, TITLE_SELECTORS).presence || squish(link&.text).presence || card.at_css("img[alt]")&.[]("alt")
        return unless name.present? && link&.[]("href").present?

        {
          name: name,
          url: without_query(link["href"]),
          address: text(card, ADDRESS_SELECTORS),
          distance: text(card, DISTANCE_SELECTORS),
          **review(card),
          **stars(card),
          price: text(card, PRICE_SELECTORS),
          taxes_note: text(card, TAXES_SELECTORS),
          stay: text(card, STAY_SELECTORS),
          image_url: lazy_first_selector_match(card, IMAGE_SELECTORS)&.[]("src")
        }
      end

      # The block reads "Puntuación: 9,1 · 9,1 · Fantástico · 12 comentarios":
      # the visible score is the aria-hidden copy; label and count are the two
      # children of the aria-visible part.
      def review(card)
        block = lazy_first_selector_match(card, REVIEW_SELECTORS)
        details = block&.at_css("> [aria-hidden=false]")&.element_children
        {
          review_score: squish(block&.at_css("> [aria-hidden=true]")&.text),
          review_label: squish(details&.first&.text),
          review_count: squish(details&.[](1)&.text)
        }
      end

      # One icon per star, as the rating element's direct children.
      def stars(card)
        STAR_KINDS.each do |selector, kind|
          rating = card.at_css(selector)
          return { stars: rating.element_children.size, stars_kind: kind } if rating
        end
        { stars: nil, stars_kind: nil }
      end

      def text(card, selectors)
        squish(lazy_first_selector_match(card, selectors)&.text)
      end

      # Booking's links carry a long tracking/session query (aid, label,
      # srpvid, …); the property page itself is the path. An href that won't
      # parse is nil rather than passed through with its tracking intact.
      def without_query(href)
        uri = URI.parse(href)
        uri.query = nil
        uri.fragment = nil
        uri.to_s
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end
