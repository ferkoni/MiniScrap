require "rails_helper"

# Offline parser spec: extracts product fields from the synthetic fixture.
# No network, no browser.
RSpec.describe Scraper::NisseiParser do
  let(:html) { Rails.root.join("spec/fixtures/nissei_search.html").read }
  subject(:results) { described_class.new.parse(html) }

  it "returns one Result per product card" do
    expect(results.length).to eq(3)
    expect(results).to all(be_a(Scraper::Result))
  end

  it "extracts title, price, availability, url and position from a card" do
    expect(results.first).to have_attributes(
      title:        "PlayStation 5 Console",
      price:        "Gs. 4.500.000",
      availability: "En stock",
      url:          "https://nissei.com/py/product/ps5-console",
      position:     1
    )
  end

  it "numbers positions 1-based in document order" do
    expect(results.map(&:position)).to eq([ 1, 2, 3 ])
  end

  it "returns an empty list when no cards are present" do
    expect(described_class.new.parse("<html><body>nada</body></html>")).to eq([])
  end
end
