require "rails_helper"

# #data is the one place a parser's output becomes the JSON-ready hash that
# both the coverage check and the controller read.
RSpec.describe Scraper::ParsedPage do
  let(:record) { Data.define(:title).new(title: "PS5") }
  let(:filters) { Data.define(:brands).new(brands: ["Sony"]) }

  it "renders a list of records as a list of hashes" do
    expect(described_class.new(results: [record, record], filters: nil).data)
      .to eq(results: [{ title: "PS5" }, { title: "PS5" }])
  end

  it "renders a single record, for a page that isn't a list, as one hash" do
    expect(described_class.new(results: record, filters: nil).data).to eq(results: { title: "PS5" })
  end

  it "renders an empty list as an empty list" do
    expect(described_class.new(results: [], filters: nil).data).to eq(results: [])
  end

  it "includes the filters when the page offers them" do
    expect(described_class.new(results: [record], filters: filters).data)
      .to eq(results: [{ title: "PS5" }], filters: { brands: ["Sony"] })
  end

  it "leaves the filters key out when the page offers none" do
    expect(described_class.new(results: [record], filters: nil).data).not_to have_key(:filters)
  end
end
