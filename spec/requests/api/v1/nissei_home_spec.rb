require "rails_helper"

# Drives the full edge path with a FakeFetcher and StubSolver injected — no
# network, no browser. The flow, error mapping and streaming are covered in
# depth by nissei_search_spec; this spec covers what the home endpoint adds:
# its path, its own parser, the carousels' follow-up request, and a shared
# clearance with search.
RSpec.describe "GET /api/v1/nissei/home", type: :request do
  let(:html) { Rails.root.join("spec/fixtures/nissei/home.html").read }
  let(:cleared) { Scraper::Response.new(status: 200, headers: {}, body: html) }
  let(:sections) { Scraper::Response.new(status: 200, headers: {}, body: Rails.root.join("spec/fixtures/nissei/home_sections.json").read) }
  let(:carousel_keys) { %w[recommended may_like continue_buying gift_ideas best_sellers] }
  let(:challenged) { Scraper::Response.new(status: 403, headers: {}, body: "Just a moment...") }

  let(:solver) { Scraper::StubSolver.new }
  let(:store) { Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new(cloudflare_js: solver)) }

  # What the fast path serves, in order (the last repeats): the page, then the
  # carousels. Contexts override it.
  let(:responses) { [cleared, sections] }
  let(:fetcher) { Scraper::FakeFetcher.new(responses: responses) }

  before do
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(fetcher)
    allow(Api::V1::ScrapeController).to receive(:clearance_store).and_return(store)
  end

  it "fetches nissei's home page, then the carousels from the page's own endpoint" do
    get "/api/v1/nissei/home"

    expect(fetcher.requests.pluck(:url)).to match([
      "https://nissei.com/py/",
      %r{\Ahttps://nissei\.com/py/aipersonalization/ajax/sections\?context=home&.*&currency=PYG&_=\d+\z}
    ])
    expect(fetcher.requests.last[:headers]).to eq("X-Requested-With" => "XMLHttpRequest")
  end

  it "returns 200 with search's envelope, minus filters (the home page has none)" do
    get "/api/v1/nissei/home"

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys).to contain_exactly("site", "results", "browser_used", "latency_ms", "coverage", "degraded")
    expect(body).to include("site" => "nissei", "browser_used" => false, "degraded" => nil)
  end

  it "returns results as keyed carousels plus a list of categories" do
    get "/api/v1/nissei/home"

    results = response.parsed_body["results"]
    expect(results.keys).to eq(%w[carousels categories])
    expect(results["carousels"].keys).to eq(carousel_keys)
    expect(results["carousels"]["recommended"]).to include(
      "title" => "Precios especiales en tus categorías top", "fallback" => false
    )
    expect(results["carousels"]["recommended"]["products"].length).to eq(10)
    expect(results["categories"].length).to eq(8)
    expect(results["categories"].first).to include(
      "title" => "Fotografía y Filmación", "url" => "https://nissei.com/py/fotografia-filmacion"
    )
    expect(results["categories"].first.keys).to eq(%w[title url products])
  end

  it "checks the home contract across carousels and categories" do
    get "/api/v1/nissei/home"

    coverage = response.parsed_body["coverage"]
    expect(coverage["results.carousels.best_sellers.products[].price"]).to eq("present" => 11, "of" => 11)
    expect(coverage["results.categories[].products[].price"]).to eq("present" => 116, "of" => 116)
    expect(coverage["results.categories[].url"]).to eq("present" => 8, "of" => 8)
    expect(response.parsed_body["degraded"]).to be_nil
  end

  it "serializes each product with the home card fields" do
    get "/api/v1/nissei/home"

    product = response.parsed_body["results"]["carousels"]["recommended"]["products"].first
    expect(product.keys).to contain_exactly(
      "title", "price", "old_price", "discount", "online_only", "free_delivery", "url", "image_url", "position"
    )
    expect(product).to include(
      "price" => "Gs. 3.690.000",
      "old_price" => "Gs. 5.300.000",
      "discount" => "-30%",
      "free_delivery" => true,
      "position" => 1
    )
  end

  context "when nissei's carousel response lacks a guaranteed carousel" do
    let(:sections) do
      data = JSON.parse(Rails.root.join("spec/fixtures/nissei/home_sections.json").read)
      data["sections"].reject! { |section| section["id"] == "gift_ideas" }
      Scraper::Response.new(status: 200, headers: {}, body: data.to_json)
    end

    it "returns it as null and flags it" do
      get "/api/v1/nissei/home"

      body = response.parsed_body
      expect(body["results"]["carousels"]).to include("gift_ideas" => nil)
      expect(body["degraded"]).to eq([{ "code" => "empty", "path" => "results.carousels.gift_ideas.products" }])
    end
  end

  # The page itself was fine, so /home still answers with the categories.
  {
    "fails" => Scraper::FetchFailed.new("timed out"),
    "is challenged" => Scraper::Response.new(status: 403, headers: {}, body: "Just a moment..."),
    "gets a 500" => Scraper::Response.new(status: 500, headers: {}, body: "error")
  }.each do |failure, carousel_response|
    context "when the carousel request #{failure}" do
      let(:responses) { [cleared, carousel_response] }

      it "returns 200 with the categories, null carousels, and why in degraded" do
        get "/api/v1/nissei/home"

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body["results"]["carousels"]).to eq(carousel_keys.index_with(nil))
        expect(body["results"]["categories"].length).to eq(8)
        expect(body["degraded"].first).to include("code" => "follow_up_failed", "name" => "carousels")
        expect(body["degraded"].drop(1)).to eq(
          carousel_keys.map { |key| { "code" => "empty", "path" => "results.carousels.#{key}.products" } }
        )
      end
    end
  end

  # Each action names its own parser: home's never reaches search.
  it "leaves search on the search parser" do
    get "/api/v1/nissei/home"
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(
      Scraper::FakeFetcher.new(responses: [Scraper::Response.new(status: 200, headers: {}, body: Rails.root.join("spec/fixtures/nissei/search.html").read)])
    )
    get "/api/v1/nissei/search", params: { q: "ps5" }

    expect(response.parsed_body["results"].first).to include("title" => "PlayStation 5 Console", "position" => 1)
  end

  context "when neither the page nor the carousel response parses to anything" do
    let(:responses) { [Scraper::Response.new(status: 200, headers: {}, body: "<html><body>redesigned</body></html>")] }

    it "returns 200 with the empty results flagged" do
      get "/api/v1/nissei/home"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["results"]).to eq("carousels" => carousel_keys.index_with(nil), "categories" => [])
      expect(body["degraded"].first(2)).to eq([{ "code" => "empty", "path" => "results" }, { "code" => "empty", "path" => "results.categories" }])
    end
  end

  context "when the site challenges the cold fast path" do
    let(:responses) { [challenged, cleared, sections] }

    it "solves, retries, and returns 200 with browser_used: true" do
      get "/api/v1/nissei/home"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["browser_used"]).to be(true)
      expect(response.parsed_body["results"]["categories"]).not_to be_empty
      expect(response.parsed_body["degraded"]).to be_nil
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

  it "streams the carousel request too when asked via ?stream=true" do
    get "/api/v1/nissei/home", params: { stream: "true" }

    expect(response.media_type).to eq("text/event-stream")
    events = response.body.split("\n\n").map do |frame|
      fields = frame.lines(chomp: true).to_h { |line| line.split(": ", 2) }
      [fields["event"], JSON.parse(fields["data"])]
    end
    expect(events.map(&:first)).to eq(%w[fast_path follow_up done])
    expect(events[1].last).to include("name" => "carousels")
    expect(events.last.last["results"]["carousels"].keys).to eq(carousel_keys)
  end
end
