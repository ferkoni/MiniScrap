require "rails_helper"

# Offline parser spec against saved pages — no network, no browser.
RSpec.describe Scraper::Nissei::SearchParser do
  def parse(fixture)
    described_class.new.parse(Rails.root.join("spec/fixtures/nissei", fixture).read)
  end

  # A real cleared nissei search page for "ps5", captured by the live solver spec.
  describe "the real captured results page" do
    subject(:results) { parse("results.html") }

    it "returns one Product per product in the listing" do
      expect(results.length).to eq(20)
      expect(results).to all(be_a(Scraper::Nissei::CardExtractor::Product))
    end

    it "extracts clean fields from a card" do
      expect(results.first).to have_attributes(
        title: "Juego PS5 Saros",
        price: "Gs. 520.000",
        online_only: nil,
        free_delivery: nil,
        url: "https://nissei.com/py/juego-ps5-saros",
        position: 1
      )
    end

    it "fills every field on every card" do
      expect(results).to all(have_attributes(title: be_present, price: start_with("Gs. "), url: start_with("https://nissei.com/py/")))
    end

    # This capture predates nissei's promo labels: no card carries one.
    it "flags no card as online-only or free-delivery" do
      expect(results).to all(have_attributes(online_only: nil, free_delivery: nil))
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
    subject(:results) { parse("results_smartphone.html") }

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

    # Search cards share the home page's card markup, sale fields included.
    it "reads sale price, old price, discount and image from a discounted card" do
      expect(results.first).to have_attributes(
        price: "Gs. 18.000",
        old_price: "Gs. 63.000",
        discount: "-71%",
        image_url: start_with("https://nissei.com/media/")
      )
      expect(results.count(&:old_price)).to eq(9)
    end

    it "flags a card labelled only \"Delivery Gratis\" as free-delivery, not online-only" do
      expect(results.first).to have_attributes(online_only: nil, free_delivery: true)
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
        online_only: nil,
        free_delivery: nil
      )
    end

    it "reads the labels per card, not page-wide" do
      expect(results.select(&:online_only).map(&:position)).to eq([26])
      expect(results.reject(&:free_delivery).map(&:position)).to eq([2, 3, 4, 32, 42, 44])
    end
  end

  # The sidebar's filter block (Amasty layered navigation) on the smartphone page.
  describe "filters on a real results page" do
    subject(:page) { described_class.new.parse_page(Rails.root.join("spec/fixtures/nissei/results_smartphone.html").read) }

    let(:filters) { page.filters }

    def flatten(categories)
      categories.flat_map { |c| [c, *flatten(c.children)] }
    end

    it "returns the products and the filters together" do
      expect(page).to be_a(Scraper::ParsedPage)
      expect(page.results.length).to eq(45)
      expect(filters).to be_a(described_class::Filters)
    end

    it "reads the top-level categories in page order" do
      expect(filters.categories.map(&:label)).to eq(
        ["Informática", "Electrónica", "Fotografía y Filmación", "Ferretería y Construcción", "Automotriz y Motocicletas", "Recomendado", "Promociones"]
      )
    end

    it "nests subcategories under their parent, to any depth" do
      informatica = filters.categories.first
      expect(informatica).to have_attributes(
        label: "Informática",
        value: "170",
        url: "https://nissei.com/py/catalogsearch/result/index/?cat=170&q=smartphone"
      )
      monitores = informatica.children.first
      expect(monitores).to have_attributes(label: "Monitores, Periféricos y Accesorios", value: "177")
      expect(monitores.children.first).to have_attributes(label: "Auriculares Gaming y Micrófonos", value: "247", children: [])
    end

    # Each category is read once, at its own level — not again inside its parent.
    it "reads every category in the tree exactly once" do
      all = flatten(filters.categories)
      expect(all.length).to eq(42)
      expect(all.map(&:value).uniq.length).to eq(42)
    end

    it "reads brands with the id nissei filters by and the URL that applies it" do
      expect(filters.brands.map(&:label)).to eq(%w[Argom DJI Godox Insta360 Microsoft Satellite Lexar SmallRig Hohem Synco])
      expect(filters.brands.first).to have_attributes(
        value: "1598",
        url: "https://nissei.com/py/catalogsearch/result/index/?marca=1598&q=smartphone"
      )
    end

    it "reads colors from the swatches" do
      expect(filters.colors.length).to eq(11)
      expect(filters.colors.first).to have_attributes(
        label: "Negro",
        value: "4672",
        url: "https://nissei.com/py/catalogsearch/result/index/?color=4672&q=smartphone"
      )
    end

    it "fills label, value and url on every option" do
      options = flatten(filters.categories) + filters.brands + filters.colors
      expect(options).to all(have_attributes(label: be_present, value: be_present, url: start_with("https://nissei.com/py/catalogsearch/")))
    end

    it "serializes deeply, category children included" do
      expect(filters.to_h[:categories].first[:children].first[:children].first).to eq(
        label: "Auriculares Gaming y Micrófonos",
        value: "247",
        url: "https://nissei.com/py/catalogsearch/result/index/?cat=247&q=smartphone",
        children: []
      )
    end
  end

  # A second real page, so the filter selectors hold beyond one capture. Its
  # labels carry nissei's stray whitespace ("Negro - Azul ").
  describe "filters on the ps5 results page" do
    subject(:filters) { described_class.new.parse_page(Rails.root.join("spec/fixtures/nissei/results.html").read).filters }

    it "reads every group" do
      expect(filters.categories.length).to eq(11)
      expect(filters.brands.length).to eq(10)
      expect(filters.colors.length).to eq(34)
    end

    it "squishes whitespace out of labels" do
      labels = filters.colors.map(&:label)
      expect(labels).to include("Negro - Azul", "Natural")
      expect(labels).to all(satisfy { |label| label == label.strip })
    end
  end

  # Every primary selector's hook is renamed or removed; only fallbacks match.
  describe "a layout-shifted page" do
    subject(:results) { parse("results_shifted.html") }

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

    it "returns empty filters when the page has no filter block" do
      filters = described_class.new.parse_page(Rails.root.join("spec/fixtures/nissei/results_shifted.html").read).filters
      expect(filters.to_h).to eq(categories: [], brands: [], colors: [])
    end
  end

  describe "the synthetic walking-skeleton page" do
    subject(:results) { parse("search.html") }

    it "still parses" do
      expect(results.map(&:title)).to include("PlayStation 5 Console")
      expect(results).to all(have_attributes(online_only: nil, free_delivery: nil))
    end
  end

  it "returns an empty list when no cards are present" do
    expect(described_class.new.parse("<html><body>nada</body></html>")).to eq([])
  end
end
