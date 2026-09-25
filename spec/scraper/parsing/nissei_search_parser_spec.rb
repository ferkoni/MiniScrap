require "rails_helper"

# Offline parser spec against saved pages — no network, no browser.
RSpec.describe Scraper::NisseiSearchParser do
  def parse(fixture)
    described_class.new.parse(Rails.root.join("spec/fixtures", fixture).read)
  end

  # A real cleared nissei search page for "ps5", captured by the live solver spec.
  describe "the real captured results page" do
    subject(:results) { parse("nissei_results.html") }

    it "returns one Result per product in the listing" do
      expect(results.length).to eq(20)
      expect(results).to all(be_a(described_class::Result))
    end

    it "extracts clean fields from a card" do
      expect(results.first).to have_attributes(
        title: "Juego PS5 Saros",
        price: "Gs. 520.000",
        online_only: false,
        free_delivery: false,
        url: "https://nissei.com/py/juego-ps5-saros",
        position: 1
      )
    end

    it "fills every field on every card" do
      expect(results).to all(have_attributes(title: be_present, price: start_with("Gs. "), url: start_with("https://nissei.com/py/")))
    end

    # This capture predates nissei's promo labels: no card carries one.
    it "flags no card as online-only or free-delivery" do
      expect(results).to all(have_attributes(online_only: false, free_delivery: false))
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

  # A second, independently captured real page (a "smartphone" search) whose
  # cards carry Amasty promo labels ("Delivery Gratis", "Solo Online").
  describe "a second real results page with promo labels" do
    subject(:results) { parse("nissei_results_smartphone.html") }

    it "extracts every product with clean fields" do
      expect(results.length).to eq(45)
      expect(results.first).to have_attributes(
        title: "Montura para Smartphone QZSD - Negro",
        price: "Gs. 18.000",
        url: "https://nissei.com/py/montura-para-smartphone-qzsd-negro",
        position: 1
      )
      expect(results).to all(have_attributes(title: be_present, price: start_with("Gs. "), url: start_with("https://nissei.com/py/")))
    end

    it "flags a card labelled only \"Delivery Gratis\" as free-delivery, not online-only" do
      expect(results.first).to have_attributes(online_only: false, free_delivery: true)
    end

    it "flags a card carrying both labels as online-only and free-delivery" do
      expect(results[25]).to have_attributes(
        title: "Electrificador de Cerca Wifi JFL Alarmes ECR 10W",
        online_only: true,
        free_delivery: true
      )
    end

    it "flags a card with no label as neither" do
      expect(results[1]).to have_attributes(
        title: "Estabilizador Hohem iSteady V3 Ultra para Smartphone",
        online_only: false,
        free_delivery: false
      )
    end

    it "reads the labels per card, not page-wide" do
      expect(results.select(&:online_only).map(&:position)).to eq([26])
      expect(results.reject(&:free_delivery).map(&:position)).to eq([2, 3, 4, 32, 42, 44])
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

    it "skips template cards that carry no product link" do
      expect(results.length).to eq(2)
    end
  end

  describe "the synthetic walking-skeleton page" do
    subject(:results) { parse("nissei_search.html") }

    it "still parses" do
      expect(results.map(&:title)).to include("PlayStation 5 Console")
      expect(results).to all(have_attributes(online_only: false, free_delivery: false))
    end
  end

  it "returns an empty list when no cards are present" do
    expect(described_class.new.parse("<html><body>nada</body></html>")).to eq([])
  end
end
