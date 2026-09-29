require "rails_helper"

# A blank string is a value that isn't one: a coverage check would count it
# as present. Every parser, on every real and hand-made fixture, returns nil
# for an empty element instead.
RSpec.describe "Parsed values are never blank strings" do
  def strings(value)
    case value
    when Hash then value.values.flat_map { |v| strings(v) }
    when Array then value.flat_map { |v| strings(v) }
    when String then [value]
    else []
    end
  end

  def fixture(path)
    Rails.root.join("spec/fixtures", path).read
  end

  {
    Scraper::Booking::SearchParser.new => %w[booking/search.html booking/search_shifted.html],
    Scraper::Nissei::SearchParser.new => %w[nissei/search.html nissei/results.html nissei/results_shifted.html nissei/results_smartphone.html],
    Scraper::Nissei::HomeParser.new => %w[nissei/home.html]
  }.each do |parser, fixtures|
    fixtures.each do |path|
      it "#{parser.class.name.demodulize} on #{path}" do
        data = parser.parse_page(fixture(path)).data

        expect(strings(data)).to all(satisfy { |s| !s.strip.empty? })
      end
    end
  end

  it "HomeParser on nissei/home.html with its carousel response" do
    data = Scraper::Nissei::HomeParser.new
      .parse_page(fixture("nissei/home.html"), follow_ups: { carousels: fixture("nissei/home_sections.json") }).data

    expect(data[:results][:carousels].values).to all(be_present)
    expect(strings(data)).to all(satisfy { |s| !s.strip.empty? })
  end

  it "squish turns blank and whitespace-only text into nil" do
    parser = Class.new { include Scraper::Parser }.new

    expect(parser.squish("")).to be_nil
    expect(parser.squish(" \n  ")).to be_nil
    expect(parser.squish(nil)).to be_nil
    expect(parser.squish("  Gs.\n 1.000 ")).to eq("Gs. 1.000")
  end
end
