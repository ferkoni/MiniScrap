require "rails_helper"

# Card-level rules, on small hand-written cards. Which cards a page yields is
# each parser's concern, covered by its own spec against the real captures.
RSpec.describe Scraper::Nissei::CardExtractor do
  def products(*cards)
    doc = Nokogiri::HTML5("<ol>#{cards.map { |card| "<li class=\"product-item\">#{card}</li>" }.join}</ol>")
    described_class.new.products(doc.css("li.product-item"))
  end

  let(:sale_card) do
    <<~HTML
      <img class="product-image-photo" src="https://nissei.com/media/tv.jpg">
      <div class="amasty-label-container"><div class="amlabel-text"> Solo Online </div></div>
      <div class="amasty-label-container"><div class="amlabel-text"> Delivery Gratis </div></div>
      <span class="discount-percent">-20%</span>
      <a class="product-item-link" href="https://nissei.com/py/tv"> Tv Smart
        LED </a>
      <span class="price-wrapper" data-price-type="finalPrice"><span class="price">Gs.&nbsp;2.390.000</span></span>
      <span class="price-wrapper" data-price-type="oldPrice"><span class="price">Gs.&nbsp;2.990.000</span></span>
    HTML
  end

  it "reads every field from a discounted card" do
    expect(products(sale_card).first).to have_attributes(
      title: "Tv Smart LED",
      price: "Gs. 2.390.000",
      old_price: "Gs. 2.990.000",
      discount: "-20%",
      online_only: true,
      free_delivery: true,
      url: "https://nissei.com/py/tv",
      image_url: "https://nissei.com/media/tv.jpg",
      position: 1
    )
  end

  it "leaves sale fields nil and flags false on a plain card" do
    card = '<a class="product-item-link" href="https://nissei.com/py/x">X</a><span class="price">Gs. 1.000</span>'

    expect(products(card).first).to have_attributes(
      price: "Gs. 1.000", old_price: nil, discount: nil, image_url: nil, online_only: false, free_delivery: false
    )
  end

  it "falls back to the link's title attribute when the link has no text" do
    card = '<a title="From Attribute" href="https://nissei.com/py/x"><img src="x.jpg"></a>'

    expect(products(card).first.title).to eq("From Attribute")
  end

  # A label that merely contains the text is not that label.
  it "matches promo labels whole" do
    card = <<~HTML
      <a class="product-item-link" href="https://nissei.com/py/x">X</a>
      <div class="amlabel-text">No Delivery Gratis</div>
      <div class="amlabel-text">Solo Online Hoy</div>
    HTML

    expect(products(card).first).to have_attributes(online_only: false, free_delivery: false)
  end

  it "skips cards without a title or link, numbering the rest 1-based" do
    no_link = '<span class="product-item-name">Template</span>'
    no_href = '<a class="product-item-link">No href</a>'
    plain = '<a class="product-item-link" href="https://nissei.com/py/y">Y</a>'

    expect(products(no_link, sale_card, no_href, plain).map { |p| [p.title, p.position] })
      .to eq([["Tv Smart LED", 1], ["Y", 2]])
  end

  it "returns an empty list for no cards" do
    expect(products).to eq([])
  end
end
