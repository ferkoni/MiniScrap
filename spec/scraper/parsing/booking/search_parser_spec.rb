require "rails_helper"

# Offline parser spec against saved pages — no network, no browser.
RSpec.describe Scraper::Booking::SearchParser do
  def parse(fixture, offset: 0)
    described_class.new(offset: offset).parse(Rails.root.join("spec/fixtures/booking", fixture).read)
  end

  # Booking's original server HTML for an Asunción search (8 nights, 2 adults),
  # fetched over the fast path with a browser-earned AWS WAF token.
  describe "the real captured results page" do
    subject(:properties) { parse("search.html") }

    it "returns one Property per card" do
      expect(properties.length).to eq(15)
      expect(properties).to all(be_a(described_class::Property))
    end

    it "extracts clean fields from a card" do
      expect(properties[4]).to have_attributes(
        name: "Danieri Asunción Hotel",
        url: "https://www.booking.com/hotel/py/di-danieri.es.html",
        address: "Asunción",
        distance: "a 6,9 km del centro",
        review_score: "8,3",
        review_label: "Muy bien",
        review_count: "1.056 comentarios",
        stars: 3,
        stars_kind: "official",
        price: "US$714",
        taxes_note: "+ US$71 de impuestos y cargos",
        stay: "8 noches, 2 adultos",
        image_url: start_with("https://cf.bstatic.com/xdata/images/hotel/square240/"),
        position: 5
      )
    end

    it "strips Booking's tracking query from every property URL" do
      expect(properties.map(&:url)).to all(match(%r{\Ahttps://www\.booking\.com/hotel/py/[\w-]+\.es\.html\z}))
    end

    it "fills name, price, stay and image on every card" do
      expect(properties).to all(have_attributes(
        name: be_present, price: start_with("US$"), stay: "8 noches, 2 adultos", image_url: be_present
      ))
    end

    # Booking draws its own "squares" rating like official stars.
    it "tells official stars from Booking's own rating" do
      expect(properties[1]).to have_attributes(name: "WELL Residences - By AVA Rentals", stars: 3, stars_kind: "booking_rating")
      expect(properties.map(&:stars_kind).tally).to eq(nil => 3, "official" => 7, "booking_rating" => 5)
    end

    it "leaves stars nil on a card with no rating" do
      expect(properties.first).to have_attributes(name: "Casa FULGENCIO", stars: nil, stars_kind: nil)
    end

    it "keeps the taxes note as shown, whether added or included" do
      expect(properties[10].taxes_note).to eq("Incluye impuestos y cargos")
    end

    it "numbers positions 1-based in document order" do
      expect(properties.map(&:position)).to eq((1..15).to_a)
    end

    it "numbers positions from the page's offset" do
      expect(parse("search.html", offset: 25).map(&:position)).to eq((26..40).to_a)
    end
  end

  # Card, link, title and image hooks are removed; only fallbacks match.
  describe "a layout-shifted page" do
    subject(:properties) { parse("search_shifted.html") }

    it "still extracts every property through the structural fallbacks" do
      expect(properties.map(&:name)).to eq(["Posada del Río", "Casa Nueva"])
      expect(properties.map(&:url)).to eq(
        ["https://www.booking.com/hotel/py/posada-del-rio.es.html", "https://www.booking.com/hotel/py/casa-nueva.es.html"]
      )
      expect(properties.first).to have_attributes(
        review_score: "8,0", review_label: "Muy bien", stars: 2, stars_kind: "official", price: "US$150",
        image_url: "https://cf.bstatic.com/xdata/images/hotel/square240/1.webp"
      )
    end

    it "falls back to the image's alt text for a link with no text" do
      expect(properties.last.name).to eq("Casa Nueva")
    end

    it "leaves review and rating fields nil on an unreviewed, unrated property" do
      expect(properties.last).to have_attributes(
        review_score: nil, review_label: nil, review_count: nil, stars: nil, stars_kind: nil,
        address: nil, taxes_note: nil
      )
    end

    it "skips cards without a link" do
      expect(properties.length).to eq(2)
    end
  end

  # Passing the raw href through would forward Booking's tracking query.
  it "leaves url nil for an href that won't parse" do
    card = <<~HTML
      <div data-testid="property-card">
        <div data-testid="title">Hotel</div>
        <a data-testid="title-link" href="https://www.booking.com/hotel/py/a b.html?aid=1&label=x">Hotel</a>
      </div>
    HTML

    expect(described_class.new.parse(card).first).to have_attributes(name: "Hotel", url: nil)
  end

  # The challenge page parses to nothing; the detector, not the parser, must catch it.
  it "returns an empty list for the AWS WAF challenge page" do
    expect(parse("challenge.html")).to eq([])
  end

  it "returns an empty list when no cards are present" do
    expect(described_class.new.parse("<html><body>nada</body></html>")).to eq([])
  end
end
