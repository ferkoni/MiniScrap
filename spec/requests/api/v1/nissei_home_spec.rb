require "rails_helper"

# Drives the full edge path with a FakeFetcher and StubSolver injected — no
# network, no browser. The flow, error mapping and streaming are covered in
# depth by nissei_search_spec; this spec covers what the home endpoint adds:
# its path, its own parser, and a shared clearance with search.
RSpec.describe "GET /api/v1/nissei/home", type: :request do
  let(:html) { Rails.root.join("spec/fixtures/nissei_home.html").read }
  let(:cleared) { Scraper::Response.new(status: 200, headers: {}, body: html) }
  let(:challenged) { Scraper::Response.new(status: 403, headers: {}, body: "Just a moment...") }

  let(:solver) { Scraper::StubSolver.new }
  let(:store) { Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new(cloudflare_js: solver)) }

  # What the fast path serves, in order (the last repeats); contexts override it.
  let(:responses) { [cleared] }
  let(:fetcher) { Scraper::FakeFetcher.new(responses: responses) }

  before do
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(fetcher)
    allow(Api::V1::ScrapeController).to receive(:clearance_store).and_return(store)
  end

  it "fetches nissei's home page, the site's base URL" do
    expect(fetcher).to receive(:fetch).with("https://nissei.com/py/", anything).and_call_original

    get "/api/v1/nissei/home"
  end

  it "returns 200 with search's JSON contract, minus filters (the home page has none)" do
    get "/api/v1/nissei/home"

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys).to contain_exactly("site", "results", "browser_used", "latency_ms", "degraded")
    expect(body).to include("site" => "nissei", "browser_used" => false, "degraded" => nil)
  end

  it "parses with the home parser: results are sections of products" do
    get "/api/v1/nissei/home"

    results = response.parsed_body["results"]
    expect(results.map { |s| s["name"] }).to eq(%w[recommended may_like continue_buying gift_ideas best_sellers] + ["category"] * 8)
    expect(results.first.keys).to contain_exactly("name", "title", "products")
    expect(results.first["title"]).to eq("Precios especiales en tus categorías top")
  end

  it "serializes each product with the home card fields" do
    get "/api/v1/nissei/home"

    product = response.parsed_body["results"].first["products"].first
    expect(product.keys).to contain_exactly(
      "title", "price", "old_price", "discount", "online_only", "free_delivery", "url", "image_url", "position"
    )
    expect(product).to include(
      "title" => "Tv Smart LED Crystal Samsung UN50U8000FG 50\" 4K Tizen - Negro",
      "price" => "Gs. 2.390.000",
      "old_price" => "Gs. 2.990.000",
      "discount" => "-20%",
      "free_delivery" => true,
      "position" => 1
    )
  end

  # The per-action parser must not leak into the Site the other actions use.
  it "leaves search on the search parser" do
    get "/api/v1/nissei/home"
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(
      Scraper::FakeFetcher.new(responses: [Scraper::Response.new(status: 200, headers: {}, body: Rails.root.join("spec/fixtures/nissei_search.html").read)])
    )
    get "/api/v1/nissei/search", params: { q: "ps5" }

    expect(response.parsed_body["results"].first).to include("title" => "PlayStation 5 Console", "position" => 1)
  end

  context "when the page parses to zero sections" do
    let(:responses) { [Scraper::Response.new(status: 200, headers: {}, body: "<html><body>redesigned</body></html>")] }

    it "returns 200 with empty results flagged degraded: zero_results" do
      get "/api/v1/nissei/home"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("results" => [], "degraded" => "zero_results")
    end
  end

  context "when the site challenges the cold fast path" do
    let(:responses) { [challenged, cleared] }

    it "solves, retries, and returns 200 with browser_used: true" do
      get "/api/v1/nissei/home"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["browser_used"]).to be(true)
      expect(response.parsed_body["results"]).not_to be_empty
    end

    # Same site id and profile, so search rides the clearance home solved.
    it "shares the solved clearance with search" do
      get "/api/v1/nissei/home"
      get "/api/v1/nissei/search", params: { q: "ps5" }

      expect(response.parsed_body["browser_used"]).to be(false)
      expect(solver.calls).to eq(1)
    end
  end

  context "when the fast path stays challenged after the solve" do
    let(:responses) { [challenged] }

    it "returns 502 retry_budget_exhausted" do
      get "/api/v1/nissei/home"

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "retry_budget_exhausted")
    end
  end

  it "streams with the home parser when asked via ?stream=true" do
    get "/api/v1/nissei/home", params: { stream: "true" }

    expect(response.media_type).to eq("text/event-stream")
    events = response.body.split("\n\n").map do |frame|
      fields = frame.lines(chomp: true).to_h { |line| line.split(": ", 2) }
      [fields["event"], JSON.parse(fields["data"])]
    end
    expect(events.map(&:first)).to eq(%w[fast_path done])
    expect(events.last.last["results"].first).to include("name" => "recommended")
  end
end
