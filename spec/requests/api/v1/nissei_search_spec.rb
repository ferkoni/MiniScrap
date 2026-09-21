require "rails_helper"

# Drives the full edge path with a FakeFetcher and StubSolver injected — no
# network, no browser.
RSpec.describe "GET /api/v1/nissei/search", type: :request do
  let(:html) { Rails.root.join("spec/fixtures/nissei_search.html").read }
  let(:cleared) { Scraper::Response.new(status: 200, headers: {}, body: html) }
  let(:challenged) { Scraper::Response.new(status: 403, headers: {}, body: "Just a moment...") }

  let(:solver) { Scraper::StubSolver.new }
  let(:registry) { Scraper::SolverRegistry.new(cloudflare_js: solver) }
  let(:store) { Scraper::ClearanceStore.new(registry: registry) }

  # What the fast path serves, in order (the last repeats); contexts override it.
  let(:responses) { [cleared] }

  before do
    # The `fetcher` hook builds the real Scraper::CurlImpersonateFetcher; stub
    # that one construction point to return a FakeFetcher primed with
    # `responses`, rather than reaching into an instance with
    # allow_any_instance_of. No subprocess ever runs.
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(Scraper::FakeFetcher.new(responses: responses))

    # A fresh store per example stands in for the process-wide singleton, so a
    # clearance cached by one example never warms the next.
    allow(Api::V1::ScrapeController).to receive(:clearance_store).and_return(store)
  end

  it "returns 200 with the JSON contract" do
    get "/api/v1/nissei/search", params: { q: "ps5" }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys).to contain_exactly("site", "results", "browser_used", "latency_ms", "degraded")
    expect(body["site"]).to eq("nissei")
    expect(body["browser_used"]).to be(false)
    expect(body["latency_ms"]).to be_a(Numeric)
    expect(body["degraded"]).to be_nil
  end

  it "shapes each result with the product-card fields" do
    get "/api/v1/nissei/search", params: { q: "ps5" }

    first = response.parsed_body["results"].first
    expect(first.keys).to contain_exactly("title", "price", "availability", "url", "position")
    expect(first).to include(
      "title" => "PlayStation 5 Console",
      "position" => 1
    )
  end

  it "wires the real curl-impersonate fetcher with the site's profile" do
    get "/api/v1/nissei/search", params: { q: "ps5" }

    expect(Scraper::CurlImpersonateFetcher).to have_received(:new).with(hash_including(profile: :chrome131))
  end

  context "when the fast path cannot be fetched at all" do
    before do
      failing = Scraper::FakeFetcher.new
      allow(failing).to receive(:fetch).and_raise(Scraper::FetchFailed, "curl: (6) Could not resolve host")
      allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(failing)
    end

    it "returns 502 fetch_failed" do
      get "/api/v1/nissei/search", params: { q: "ps5" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "fetch_failed")
    end
  end

  # No route is drawn for an unsupported site, so it never reaches a controller.
  it "returns 404 for an unknown site" do
    get "/api/v1/amazon/search", params: { q: "ps5" }
    expect(response).to have_http_status(:not_found)
  end

  # Cold start then warm hit: the second request rides the clearance the
  # first one solved, which is exactly what `browser_used` makes visible.
  context "when the site challenges the cold fast path" do
    let(:responses) { [challenged, cleared] }

    it "solves, retries, and returns 200 with browser_used: true" do
      get "/api/v1/nissei/search", params: { q: "ps5" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["browser_used"]).to be(true)
      expect(response.parsed_body["results"]).not_to be_empty
    end

    it "serves the next request from the cached clearance with browser_used: false" do
      get "/api/v1/nissei/search", params: { q: "ps5" }
      get "/api/v1/nissei/search", params: { q: "xbox" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["browser_used"]).to be(false)
      expect(solver.calls).to eq(1)
    end
  end

  context "when the fast path stays challenged after the solve" do
    let(:responses) { [challenged] }

    it "returns 502 retry_budget_exhausted" do
      get "/api/v1/nissei/search", params: { q: "ps5" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "retry_budget_exhausted")
    end
  end

  context "when the solve fails" do
    let(:responses) { [challenged] }

    before { allow(solver).to receive(:solve).and_raise(Scraper::SolveFailed) }

    it "returns 502 solve_failed" do
      get "/api/v1/nissei/search", params: { q: "ps5" }

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "solve_failed")
    end
  end

  context "when the solve exceeds its deadline" do
    let(:responses) { [challenged] }

    before { allow(solver).to receive(:solve).and_raise(Scraper::SolveTimeout) }

    it "returns 504 solve_timeout" do
      get "/api/v1/nissei/search", params: { q: "ps5" }

      expect(response).to have_http_status(:gateway_timeout)
      expect(response.parsed_body).to eq("error" => "solve_timeout")
    end
  end

  context "when the fetch is challenged and no solver is registered" do
    let(:registry) { Scraper::SolverRegistry.new }
    let(:responses) { [challenged] }

    it "returns 501 with the challenge kind" do
      get "/api/v1/nissei/search", params: { q: "ps5" }

      expect(response).to have_http_status(:not_implemented)
      expect(response.parsed_body).to eq(
        "error" => "unsupported_challenge",
        "kind" => "cloudflare_js"
      )
    end
  end
end
