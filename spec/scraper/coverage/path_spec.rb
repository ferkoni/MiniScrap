require "rails_helper"

RSpec.describe Scraper::Coverage::Path do
  def matches(source, data)
    described_class.new(source).matches(data).map { |match| [match.path, match.value] }
  end

  describe "parsing" do
    it "splits keys and marks the ones that fan out" do
      path = described_class.new("results[].products[].title")

      expect(path.segments.map { |s| [s.key, s.each] }).to eq([["results", true], ["products", true], ["title", false]])
      expect(path).to be_each
      expect(described_class.new("filters.brands")).not_to be_each
    end

    it "rejects a malformed path when it is built" do
      ["", "results..price", "Results", "results[0].price", "results[]", "results.price[]", "a b"].each do |source|
        expect { described_class.new(source) }.to raise_error(ArgumentError, /coverage path/), source.inspect
      end
    end
  end

  describe "resolving" do
    let(:data) do
      { results: [{ title: "A", products: [{ price: "1" }] }, { title: nil, products: [] }], filters: { brands: [] } }
    end

    it "reaches a top-level key" do
      expect(matches("filters", data)).to eq([["filters", { brands: [] }]])
    end

    it "reaches nested keys" do
      expect(matches("filters.brands", data)).to eq([["filters.brands", []]])
    end

    it "fans out over every element, naming each by index" do
      expect(matches("results[].title", data)).to eq([["results[0].title", "A"], ["results[1].title", nil]])
    end

    it "fans out through nested arrays, skipping empty ones" do
      expect(matches("results[].products[].price", data)).to eq([["results[0].products[0].price", "1"]])
    end

    it "reaches nothing through a missing key" do
      expect(matches("results[].stars", data)).to eq([])
      expect(matches("search.results", data)).to eq([])
    end

    it "reaches nothing through nil or a non-array under []" do
      expect(matches("results[].title", { results: nil })).to eq([])
      expect(matches("results[].title", { results: { title: "A" } })).to eq([])
      expect(matches("filters.brands", { filters: nil })).to eq([])
    end

    it "reads string keys as well as symbol keys" do
      expect(matches("results[].title", { "results" => [{ "title" => "A" }] })).to eq([["results[0].title", "A"]])
    end
  end
end
