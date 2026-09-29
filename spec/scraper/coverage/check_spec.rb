require "rails_helper"

RSpec.describe Scraper::Coverage::Check do
  def check(data, non_empty: [], required: [])
    described_class.new(Scraper::Coverage::Contract.new(non_empty: non_empty, required: required)).call(data)
  end

  describe "missing values" do
    it "counts nil, blank strings, empty arrays and empty objects as missing" do
      [nil, "", [], {}, { a: [], b: nil }].each do |value|
        expect(Scraper::Coverage.missing?(value)).to be(true), value.inspect
      end
    end

    it "counts false, 0 and anything with content as present" do
      [false, 0, " x", [nil], { a: [1], b: [] }].each do |value|
        expect(Scraper::Coverage.missing?(value)).to be(false), value.inspect
      end
    end
  end

  describe "coverage" do
    let(:data) do
      {
        results: [
          { title: "A", price: "1", products: [{ url: "u1" }, { url: nil }] },
          { title: "B", price: nil, products: [] },
          { title: "C", price: "", products: [{ url: "u3" }] }
        ],
        filters: { brands: [], colors: [{ label: "Red" }] }
      }
    end

    subject(:coverage) { check(data).coverage }

    it "counts, for every leaf, the items holding a value out of those with the key" do
      expect(coverage["results[].title"]).to eq("present" => 3, "of" => 3)
      expect(coverage["results[].price"]).to eq("present" => 1, "of" => 3)
    end

    it "gives arrays their total element count, summed across parents" do
      expect(coverage["results"]).to eq("count" => 3, "present" => 1, "of" => 1)
      expect(coverage["results[].products"]).to eq("count" => 3, "present" => 2, "of" => 3)
    end

    it "aggregates nested fields across every parent" do
      expect(coverage["results[].products[].url"]).to eq("present" => 2, "of" => 3)
    end

    it "counts objects, and walks into them" do
      expect(coverage["filters"]).to eq("present" => 1, "of" => 1)
      expect(coverage["filters.brands"]).to eq("count" => 0, "present" => 0, "of" => 1)
      expect(coverage["filters.colors[].label"]).to eq("present" => 1, "of" => 1)
    end

    it "keys entries by path, in the data's order" do
      expect(coverage.keys).to eq(
        %w[results results[].title results[].price results[].products results[].products[].url
           filters filters.brands filters.colors filters.colors[].label]
      )
    end

    it "is empty for empty data" do
      expect(check({}).coverage).to eq({})
    end
  end

  describe "non_empty" do
    it "passes an array or object with content" do
      expect(check({ results: [{ a: 1 }], filters: { brands: [1], colors: [] } }, non_empty: %w[results filters]).issues).to eq([])
    end

    it "flags an empty array" do
      expect(check({ results: [] }, non_empty: %w[results]).issues).to eq([{ "code" => "empty", "path" => "results" }])
    end

    it "flags an object whose every value is missing" do
      issues = check({ filters: { categories: [], brands: [], colors: [] } }, non_empty: %w[filters]).issues

      expect(issues).to eq([{ "code" => "empty", "path" => "filters" }])
    end

    it "flags a declared path that is absent from the data" do
      expect(check({ results: [1] }, non_empty: %w[filters]).issues).to eq([{ "code" => "empty", "path" => "filters" }])
    end

    it "applies under [] to every element, naming each failure by index" do
      data = { results: [{ products: [1] }, { products: [] }, { products: [2] }, { products: [] }] }

      expect(check(data, non_empty: %w[results[].products]).issues).to eq(
        [{ "code" => "empty", "path" => "results[1].products" }, { "code" => "empty", "path" => "results[3].products" }]
      )
    end

    it "reports an empty parent once, not again for every element rule beneath it" do
      issues = check({ results: [] }, non_empty: %w[results results[].products]).issues

      expect(issues).to eq([{ "code" => "empty", "path" => "results" }])
    end
  end

  describe "required" do
    it "passes a field present on at least one item" do
      data = { results: [{ price: nil }, { price: "1" }, { price: "" }] }

      expect(check(data, required: %w[results[].price]).issues).to eq([])
    end

    it "flags a field missing on every item" do
      data = { results: [{ price: nil }, { price: "" }, { price: nil }] }

      expect(check(data, required: %w[results[].price]).issues).to eq(
        [{ "code" => "missing_field", "path" => "results[].price", "present" => 0, "of" => 3 }]
      )
    end

    # Parsers' value objects always carry every key; a key no item has isn't
    # part of this output's shape, so there is nothing to count.
    it "skips a field no item has as a key" do
      data = { results: [{ title: "A" }] }

      expect(check(data, non_empty: %w[results], required: %w[results[].price]).issues).to eq([])
    end

    it "aggregates across parents: one parent's items can satisfy the rule" do
      data = { results: [{ products: [{ price: nil }] }, { products: [{ price: "1" }] }] }

      expect(check(data, required: %w[results[].products[].price]).issues).to eq([])
    end

    it "is skipped when there are no items, leaving the empty parent to non_empty" do
      issues = check({ results: [] }, non_empty: %w[results], required: %w[results[].price results[].url]).issues

      expect(issues).to eq([{ "code" => "empty", "path" => "results" }])
    end
  end

  it "lists issues in contract order: empties, then missing fields" do
    data = { results: [{ price: nil, url: nil }], filters: { brands: [] } }
    issues = check(data, non_empty: %w[results filters], required: %w[results[].url results[].price]).issues

    expect(issues.map { |issue| issue["path"] }).to eq(%w[filters results[].url results[].price])
  end

  it "defaults to flagging an empty parse" do
    report = described_class.new(Scraper::Coverage::Contract::DEFAULT).call({ results: [] })

    expect(report.issues).to eq([{ "code" => "empty", "path" => "results" }])
  end

  # The real home page and carousel response, under the contract /home declares.
  it "accepts the real home page and its carousels under the home contract" do
    fixtures = Rails.root.join("spec/fixtures/nissei")
    data = Scraper::Nissei::HomeParser.new.parse_page(
      fixtures.join("home.html").read, follow_ups: { carousels: fixtures.join("home_sections.json").read }
    ).data
    report = described_class.new(Api::V1::NisseiController::HOME_CONTRACT).call(data)

    expect(report.coverage["results.categories[].products[].price"]).to eq("present" => 116, "of" => 116)
    expect(report.coverage["results.carousels.recommended.products[].discount"]).to eq("present" => 10, "of" => 10)
    expect(report.issues).to eq([])
  end
end
