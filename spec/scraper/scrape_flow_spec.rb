require "rails_helper"

# The orchestrator runs Rails-free: built from a Site + an injected Fetcher,
# it returns a ScrapeResult with no controller, no HTTP, no browser.
RSpec.describe Scraper::ScrapeFlow do
  let(:html) { Rails.root.join("spec/fixtures/nissei_search.html").read }
  let(:fetcher) { Scraper::FakeFetcher.new(body: html) }
  let(:site) do
    Scraper::Site.new(
      id:          "nissei",
      base_url:    "https://nissei.com/py/",
      profile:     :chrome131,
      parser:      Scraper::NisseiParser.new,
      search_path: ->(q) { "search?q=#{CGI.escape(q)}" }
    )
  end

  subject(:result) { described_class.new(site: site, fetcher: fetcher).run("ps5") }

  it "returns a ScrapeResult for the site" do
    expect(result).to be_a(Scraper::ScrapeResult)
    expect(result.site).to eq("nissei")
  end

  it "marks the fast path as browser_used: false with a recorded latency" do
    expect(result.browser_used).to be(false)
    expect(result.latency_ms).to be_a(Numeric).and be >= 0
  end

  it "parses the fetched body through the site's parser" do
    expect(result.results.map(&:title)).to include("PlayStation 5 Console")
  end

  it "fetches the site's composed search URL" do
    expect(fetcher).to receive(:fetch)
      .with("https://nissei.com/py/search?q=ps5", ua: nil, cookies: {}, headers: {})
      .and_call_original
    result
  end
end
