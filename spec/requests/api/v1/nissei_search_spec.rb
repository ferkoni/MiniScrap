require "rails_helper"

# Drives the full edge path with a FakeFetcher injected — no network, no browser.
RSpec.describe "GET /api/v1/nissei/search", type: :request do
  let(:html) { Rails.root.join("spec/fixtures/nissei_search.html").read }

  # The slice-1 `fetcher` hook builds a Scraper::FakeFetcher; stub that one
  # construction point to return a fetcher primed with the fixture, rather than
  # reaching into an instance with allow_any_instance_of.
  before do
    fake = Scraper::FakeFetcher.new(body: html)
    allow(Scraper::FakeFetcher).to receive(:new).and_return(fake)
  end

  it "returns 200 with the JSON contract" do
    get "/api/v1/nissei/search", params: { q: "ps5" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys).to contain_exactly("site", "results", "browser_used", "latency_ms")
    expect(body["site"]).to eq("nissei")
    expect(body["browser_used"]).to be(false)
    expect(body["latency_ms"]).to be_a(Numeric)
  end

  it "shapes each result with the product-card fields" do
    get "/api/v1/nissei/search", params: { q: "ps5" }

    first = response.parsed_body["results"].first
    expect(first.keys).to contain_exactly("title", "price", "availability", "url", "position")
    expect(first).to include(
      "title"    => "PlayStation 5 Console",
      "position" => 1
    )
  end

  # No route is drawn for an unsupported site, so it never reaches a controller.
  it "returns 404 for an unknown site" do
    get "/api/v1/amazon/search", params: { q: "ps5" }
    expect(response).to have_http_status(:not_found)
  end
end
