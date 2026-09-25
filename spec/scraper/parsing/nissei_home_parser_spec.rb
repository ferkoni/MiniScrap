require "rails_helper"

# Offline parser spec against a saved page — no network, no browser.
RSpec.describe Scraper::NisseiHomeParser do
  def parse(fixture)
    described_class.new.parse(Rails.root.join("spec/fixtures", fixture).read)
  end

  # A real cleared nissei home page.
  describe "the real captured home page" do
    subject(:sections) { parse("nissei_home.html") }

    def section(name)
      sections.find { |s| s.name == name }
    end

    it "returns the carousels first, then one Section per category showcase" do
      expect(sections).to all(be_a(described_class::Section))
      expect(sections.map(&:name)).to eq(%w[recommended may_like continue_buying gift_ideas best_sellers] + ["category"] * 8)
    end

    it "titles each section with the heading the page shows" do
      expect(sections.map(&:title)).to eq([
        "Precios especiales en tus categorías top",
        "Tus próximas compras favoritas",
        "Descubrimientos que no tenías planeados",
        "Nuestra selección para regalar",
        "Los Más Vendidos",
        "Fotografía y Filmación",
        "Smartphones y Accesorios",
        "Smart Home",
        "Cuidado Personal y Belleza",
        "Videojuegos y Accesorios",
        "Audio Portátil",
        "Informática y Accesorios",
        "Relojes Inteligentes"
      ])
    end

    it "extracts every card of every section" do
      expect(sections.map { |s| s.products.length }).to eq([10, 12, 12, 12, 11, 14, 14, 14, 14, 14, 14, 18, 14])
      expect(sections.flat_map(&:products)).to all(be_a(described_class::Product))
    end

    it "extracts clean fields from a discounted card" do
      expect(section("recommended").products.first).to have_attributes(
        title: "Tv Smart LED Crystal Samsung UN50U8000FG 50\" 4K Tizen - Negro",
        price: "Gs. 2.390.000",
        old_price: "Gs. 2.990.000",
        discount: "-20%",
        online_only: false,
        free_delivery: true,
        url: "https://nissei.com/py/tv-smart-led-crystal-samsung-un50u8000fg-50-4k-tizen-negro",
        image_url: "https://nissei.com/media/catalog/product/cache/c831b74073e8f93ee349897f877fc397/c/e/celer_image_8_-_2026-03-05t075254.337.jpg",
        position: 1
      )
    end

    it "leaves old_price and discount nil on a card that is not on sale" do
      expect(sections.last.products.first).to have_attributes(
        title: start_with("Apple Watch SE 3"),
        price: "Gs. 2.445.000",
        old_price: nil,
        discount: nil
      )
    end

    it "reads a discount on a card outside the recommended carousel" do
      expect(section("best_sellers").products.first).to have_attributes(
        title: "Auricular Xiaomi Redmi Buds 6 Play M2420E1",
        price: "Gs. 65.000",
        old_price: "Gs. 85.000",
        discount: "-24%",
        free_delivery: false
      )
    end

    it "reads the promo labels per card" do
      expect(section("gift_ideas").products).to all(have_attributes(online_only: true))
      expect(section("best_sellers").products).to all(have_attributes(online_only: false))
      expect(section("recommended").products).to all(have_attributes(free_delivery: true))
    end

    # The page renders this card with an empty price block.
    it "leaves price nil when the card shows none" do
      expect(section("continue_buying").products[10]).to have_attributes(
        title: "Termo Totto Ribery AC63IND100",
        price: nil,
        online_only: true
      )
    end

    it "fills title, url and image on every card" do
      expect(sections.flat_map(&:products)).to all(have_attributes(
        title: be_present,
        url: start_with("https://nissei.com/py/"),
        image_url: start_with("https://nissei.com/media/")
      ))
    end

    it "numbers positions 1-based within each section" do
      sections.each do |s|
        expect(s.products.map(&:position)).to eq((1..s.products.length).to_a)
      end
    end

    it "serializes a section deeply, products included" do
      hash = sections.first.to_h
      expect(hash.keys).to contain_exactly(:name, :title, :products)
      expect(hash[:products].first).to be_a(Hash).and include(title: start_with("Tv Smart LED"), position: 1)
    end
  end

  it "returns an empty list when no sections are present" do
    expect(described_class.new.parse("<html><body>nada</body></html>")).to eq([])
  end
end
