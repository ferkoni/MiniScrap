require "rails_helper"

# The orchestrator runs Rails-free: built from a Site + an injected Fetcher,
# it returns a ScrapeResult with no controller, no HTTP, no browser.
RSpec.describe Scraper::ScrapeFlow do
  let(:html) { Rails.root.join("spec/fixtures/nissei_search.html").read }
  let(:fetcher) { Scraper::FakeFetcher.new(body: html) }
  let(:detector) { Scraper::CompositeDetector.new([Scraper::CloudflareDetector.new]) }
  let(:site) do
    Scraper::Site.new(
      id: "nissei",
      base_url: "https://nissei.com/py/",
      profile: :chrome131,
      parser: Scraper::NisseiParser.new
    )
  end

  subject(:result) do
    described_class.new(site: site, fetcher: fetcher, detector: detector).run("search?q=ps5")
  end

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

  # A detected challenge has no solver wired in this slice, so the flow fails
  # honestly rather than parsing an interstitial into empty results.
  context "when the fetched Response carries a challenge" do
    let(:fetcher) { Scraper::FakeFetcher.new(status: 403, body: "Just a moment...") }

    it "raises UnsupportedChallenge carrying the detected kind" do
      expect { result }.to raise_error(Scraper::UnsupportedChallenge) do |error|
        expect(error.kind).to eq(:cloudflare_js)
      end
    end

    it "does not parse the challenge body" do
      expect(site.parser).not_to receive(:parse)
      expect { result }.to raise_error(Scraper::UnsupportedChallenge)
    end
  end
end
