require "rails_helper"

# Offline parser spec against saved pages — no network, no browser.
RSpec.describe Scraper::NisseiParser do
  def parse(fixture)
    described_class.new.parse(Rails.root.join("spec/fixtures", fixture).read)
  end

  # A real cleared nissei search page for "ps5", captured by the live solver spec.
  describe "the real captured results page" do
    subject(:results) { parse("nissei_results.html") }

    it "returns one Result per product in the listing" do
      expect(results.length).to eq(20)
      expect(results).to all(be_a(Scraper::Result))
    end

    it "extracts clean fields from a card" do
      expect(results.first).to have_attributes(
        title: "Juego PS5 Saros",
        price: "Gs. 520.000",
        availability: "in_stock",
        url: "https://nissei.com/py/juego-ps5-saros",
        position: 1
      )
    end

    it "fills every field on every card" do
      expect(results).to all(have_attributes(title: be_present, price: start_with("Gs. "), availability: "in_stock", url: start_with("https://nissei.com/py/")))
    end

    it "numbers positions 1-based in document order" do
      expect(results.map(&:position)).to eq((1..20).to_a)
    end

    # The page also holds a wishlist-sidebar Knockout template with the same
    # .product-item class; it must not leak in as a phantom 21st result.
    it "ignores product-item templates outside the result listing" do
      expect(results.map(&:title)).to all(be_present)
    end
  end

  # Every primary selector's hook is renamed or removed; only fallbacks match.
  describe "a layout-shifted page" do
    subject(:results) { parse("nissei_results_shifted.html") }

    it "still extracts every product through the fallback selectors" do
      expect(results.map(&:title)).to eq(["Consola Sony PlayStation 5 Slim", "Control PS5 DualSense"])
      expect(results.map(&:price)).to eq(["Gs. 4.290.000", "Gs. 589.000"])
      expect(results.map(&:url)).to eq(
        ["https://nissei.com/py/consola-sony-playstation-5-slim", "https://nissei.com/py/control-ps5-dualsense"]
      )
    end

    it "reads availability from Magento's stock markers" do
      expect(results.map(&:availability)).to eq(%w[in_stock out_of_stock])
    end

    it "skips template cards that carry no product link" do
      expect(results.length).to eq(2)
    end
  end

  describe "the synthetic walking-skeleton page" do
    subject(:results) { parse("nissei_search.html") }

    it "still parses" do
      expect(results.map(&:title)).to include("PlayStation 5 Console")
      expect(results.map(&:availability)).to eq(%w[in_stock in_stock out_of_stock])
    end
  end

  it "returns an empty list when no cards are present" do
    expect(described_class.new.parse("<html><body>nada</body></html>")).to eq([])
  end
end
