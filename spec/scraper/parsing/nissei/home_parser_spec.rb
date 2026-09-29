require "rails_helper"

# Offline parser spec against saved responses — no network, no browser.
RSpec.describe Scraper::Nissei::HomeParser do
  let(:page) { Rails.root.join("spec/fixtures/nissei/home.html").read }
  # nissei's carousel endpoint, as the page's script receives it.
  let(:sections_json) { Rails.root.join("spec/fixtures/nissei/home_sections.json").read }
  let(:carousel_keys) { %w[recommended may_like continue_buying gift_ideas best_sellers] }

  def parse(html = page, follow_ups: { carousels: sections_json })
    described_class.new.parse_page(html, follow_ups: follow_ups).results
  end

  # The same JSON without the sections named by `ids`.
  def json_without(*ids)
    data = JSON.parse(sections_json)
    data["sections"].reject! { |section| ids.include?(section["id"]) }
    data.to_json
  end

  describe "the real page and carousel response" do
    subject(:home) { parse }

    it "returns a Home of keyed carousels and a list of categories" do
      expect(home).to be_a(described_class::Home)
      expect(home.carousels.keys).to eq(carousel_keys)
      expect(home.carousels.values).to all(be_a(described_class::Carousel))
      expect(home.categories).to all(be_a(described_class::Category))
    end

    it "titles each carousel from the JSON and passes is_fallback through" do
      expect(home.carousels.transform_values(&:title)).to eq(
        "recommended" => "Precios especiales en tus categorías top",
        "may_like" => "Tus próximas compras favoritas",
        "continue_buying" => "Descubrimientos que no tenías planeados",
        "gift_ideas" => "Nuestra selección para regalar",
        "best_sellers" => "Los Más Vendidos"
      )
      expect(home.carousels.values.map(&:fallback)).to all(be(false))
    end

    it "extracts every card of every carousel" do
      expect(home.carousels.transform_values { |carousel| carousel.products.length }).to eq(
        "recommended" => 10, "may_like" => 12, "continue_buying" => 12, "gift_ideas" => 12, "best_sellers" => 11
      )
    end

    it "ignores continue_browsing, which follows whichever visitor nissei rendered it for" do
      expect(JSON.parse(sections_json)["sections"].pluck("id")).to include("continue_browsing")
      expect(home.carousels.keys).not_to include("continue_browsing")
    end

    it "extracts clean fields from a discounted carousel card" do
      expect(home.carousels["recommended"].products.first).to have_attributes(
        title: "Aspiradora Inteligente Samsung VR30T85513W/ZS-E JetBot con Sensor LiDar - Blanco",
        price: "Gs. 3.690.000",
        old_price: "Gs. 5.300.000",
        discount: "-30%",
        online_only: true,
        free_delivery: true,
        url: "https://nissei.com/py/aspiradora-inteligente-samsung-vr30t85513w-zs-e-jetbot-con-sensor-lidar-blanco",
        image_url: start_with("https://nissei.com/media/catalog/product/cache/"),
        position: 1
      )
    end

    it "reads the promo labels per carousel card" do
      expect(home.carousels["gift_ideas"].products).to all(have_attributes(online_only: true))
      expect(home.carousels["best_sellers"].products).to all(have_attributes(online_only: nil))
      expect(home.carousels["recommended"].products).to all(have_attributes(free_delivery: true))
    end

    it "titles each category with the heading the page shows" do
      expect(home.categories.map(&:title)).to eq([
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

    # The heading's link is editorial, not derived from the title: "Smart
    # Home" links to televisions. The page mixes relative and absolute hrefs.
    it "gives each category the absolute URL its heading links to" do
      expect(home.categories.map(&:url)).to eq([
        "https://nissei.com/py/fotografia-filmacion",
        "https://nissei.com/py/electronica/celulares-tabletas/celulares-accesorios/",
        "https://nissei.com/py/electronica/televisores-home-theaters/televisores",
        "https://nissei.com/py/belleza-salud-cosmeticos",
        "https://nissei.com/py/videojuegos/consolas",
        "https://nissei.com/py/audio/",
        "https://nissei.com/py/informatica",
        "https://nissei.com/py/electronica/relojes-inteligentes/"
      ])
    end

    it "extracts every card of every category" do
      expect(home.categories.map { |category| category.products.length }).to eq([14, 14, 14, 14, 14, 14, 18, 14])
    end

    it "leaves old_price and discount nil on a card that is not on sale" do
      expect(home.categories.last.products.first).to have_attributes(
        title: start_with("Apple Watch SE 3"),
        price: "Gs. 2.445.000",
        old_price: nil,
        discount: nil
      )
    end

    it "fills title, url and image on every card" do
      products = home.carousels.values.flat_map(&:products) + home.categories.flat_map(&:products)
      expect(products).to all(be_a(Scraper::Nissei::CardExtractor::Product))
      expect(products).to all(have_attributes(
        title: be_present,
        url: start_with("https://nissei.com/py/"),
        image_url: start_with("https://nissei.com/media/")
      ))
    end

    it "numbers positions 1-based within each carousel and category" do
      (home.carousels.values + home.categories).each do |section|
        expect(section.products.map(&:position)).to eq((1..section.products.length).to_a)
      end
    end

    it "serializes deeply, products included" do
      hash = home.to_h
      expect(hash.keys).to eq(%i[carousels categories])
      expect(hash[:carousels]["recommended"].keys).to eq(%i[title fallback products])
      expect(hash[:carousels]["recommended"][:products].first).to include(title: start_with("Aspiradora"), position: 1)
      expect(hash[:categories].first.keys).to eq(%i[title url products])
    end
  end

  describe "an absent carousel" do
    it "is nil when the JSON lacks its section" do
      home = parse(follow_ups: { carousels: json_without("gift_ideas") })

      expect(home.carousels["gift_ideas"]).to be_nil
      expect(home.carousels.except("gift_ideas").values).to all(be_a(described_class::Carousel))
    end

    it "keeps its key when serialized" do
      hash = parse(follow_ups: { carousels: json_without("gift_ideas") }).to_h

      expect(hash[:carousels]).to include("gift_ideas" => nil)
      expect(hash[:carousels].keys).to eq(carousel_keys)
    end

    it "is a carousel with no products when its section has no cards" do
      data = JSON.parse(sections_json)
      data["sections"].find { |section| section["id"] == "bestsellers" }["html"] = "<div>nada</div>"

      expect(parse(follow_ups: { carousels: data.to_json }).carousels["best_sellers"])
        .to have_attributes(title: "Los Más Vendidos", products: [])
    end
  end

  {
    "no carousel response" => {},
    "a failed carousel request" => { carousels: nil },
    "a body that isn't JSON" => { carousels: "<html>Just a moment...</html>" },
    "JSON of another shape" => { carousels: '["sections"]' }
  }.each do |situation, follow_ups|
    it "gives every carousel nil for #{situation}, keeping the categories" do
      home = parse(follow_ups: follow_ups)

      expect(home.carousels).to eq(carousel_keys.index_with(nil))
      expect(home.categories.length).to eq(8)
    end
  end

  describe "category URLs" do
    def category(href)
      %(<div class="block-main-product"><h2 class="title"><a href="#{href}">Audio</a></h2></div>)
    end

    it "resolves a relative href against nissei" do
      expect(parse(category("/py/audio"), follow_ups: {}).categories.first.url).to eq("https://nissei.com/py/audio")
    end

    it "keeps an absolute href" do
      expect(parse(category("https://nissei.com/py/audio/"), follow_ups: {}).categories.first.url).to eq("https://nissei.com/py/audio/")
    end

    it "is nil for an unparsable href" do
      expect(parse(category("http://exa mple.com/%"), follow_ups: {}).categories.first.url).to be_nil
    end

    it "is nil for a heading without a link" do
      html = %(<div class="block-main-product"><h2 class="title">Audio</h2></div>)
      expect(parse(html, follow_ups: {}).categories.first).to have_attributes(title: "Audio", url: nil)
    end
  end

  it "declares the carousel endpoint as its follow-up, with X-Requested-With" do
    follow_up = described_class.new.follow_ups.sole

    expect(follow_up.name).to eq(:carousels)
    expect(follow_up.path).to match(
      %r{\Aaipersonalization/ajax/sections\?context=home&sections=%5B%22ofertas_recomendadas%22%2C%22continue_browsing%22%2C%22you_may_like%22%5D&currency=PYG&_=\d{13}\z}
    )
    expect(follow_up.headers).to eq("X-Requested-With" => "XMLHttpRequest")
  end

  it "returns no categories and all-nil carousels for an empty page" do
    home = parse("<html><body>nada</body></html>", follow_ups: {})

    expect(home.to_h).to eq(carousels: carousel_keys.index_with(nil), categories: [])
  end
end
