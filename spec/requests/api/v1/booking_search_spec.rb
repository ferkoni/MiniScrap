require "rails_helper"

# Drives the full edge path with a FakeFetcher and StubSolver injected — no
# network, no browser. Fixtures are Booking's real AWS WAF challenge (202)
# and its real results page.
RSpec.describe "GET /api/v1/booking/search", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:challenge) { Scraper::Response.new(status: 202, headers: { "content-type" => "text/html" }, body: fixture("challenge.html")) }
  let(:cleared) { Scraper::Response.new(status: 200, headers: {}, body: fixture("search.html")) }

  let(:solver) { Scraper::StubSolver.new }
  let(:store) { Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new(aws_waf: solver)) }

  # What the fast path serves, in order (the last repeats); contexts override it.
  let(:responses) { [cleared] }
  let(:fetcher) { Scraper::FakeFetcher.new(responses: responses) }

  let(:params) { { dest_id: "-910015", dest_type: "city", checkin: "2026-09-30", checkout: "2026-10-08", adults: 2 } }

  def fixture(name)
    Rails.root.join("spec/fixtures/booking", name).read
  end

  before do
    travel_to Time.utc(2026, 9, 25, 12)
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(fetcher)
    allow(Api::V1::ScrapeController).to receive(:clearance_store).and_return(store)
  end

  after { travel_back }

  def search(overrides = {})
    get "/api/v1/booking/search", params: params.merge(overrides).compact
  end

  it "returns 200 with the JSON contract" do
    search

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.keys).to contain_exactly("site", "results", "browser_used", "latency_ms", "degraded")
    expect(response.parsed_body).to include("site" => "booking", "browser_used" => false, "degraded" => nil)
  end

  it "shapes each result with the property-card fields" do
    search

    results = response.parsed_body["results"]
    expect(results.length).to eq(15)
    expect(results.first.keys).to contain_exactly(
      "name", "url", "address", "distance", "review_score", "review_label", "review_count",
      "stars", "stars_kind", "price", "taxes_note", "stay", "image_url", "position"
    )
    expect(results.first).to include("name" => "Casa FULGENCIO", "price" => "US$208", "position" => 1)
  end

  describe "the URL sent to Booking" do
    def requested_url
      url = nil
      allow(fetcher).to receive(:fetch).and_wrap_original { |original, u, **options| url = u; original.call(u, **options) }
      yield
      URI(url)
    end

    def query(url) = URI.decode_www_form(url.query).to_h

    it "is rebuilt from the typed params, in Booking's names, with the currency pinned" do
      url = requested_url { search(rooms: 1, children: 0) }

      expect("#{url.scheme}://#{url.host}#{url.path}").to eq("https://www.booking.com/searchresults.es.html")
      expect(query(url)).to eq(
        "dest_id" => "-910015", "dest_type" => "city", "checkin" => "2026-09-30", "checkout" => "2026-10-08",
        "group_adults" => "2", "no_rooms" => "1", "group_children" => "0", "offset" => "0", "selected_currency" => "USD"
      )
    end

    it "forwards nothing the client sends beyond the known params" do
      url = requested_url { search(sid: "session-id", aid: "111111", label: "tracking", ac_meta: "x", q: "evil") }

      expect(query(url).keys).not_to include("sid", "aid", "label", "ac_meta", "q")
    end

    it "uses free-text ss when there is no dest_id" do
      url = requested_url { search(dest_id: nil, dest_type: nil, ss: "  Asuncion ") }

      expect(query(url)).to include("ss" => "Asuncion").and(satisfy { |q| !q.key?("dest_id") })
    end

    it "prefers dest_id over ss, so Booking can't reinterpret the destination" do
      url = requested_url { search(ss: "Asuncion") }

      expect(query(url)).to include("dest_id" => "-910015").and(satisfy { |q| !q.key?("ss") })
    end

    it "defaults adults, rooms, children and offset" do
      url = requested_url { search(adults: nil) }

      expect(query(url)).to include("group_adults" => "2", "no_rooms" => "1", "group_children" => "0", "offset" => "0")
    end
  end

  it "forwards offset and numbers positions from it" do
    search(offset: 25)

    expect(response.parsed_body["results"].map { |r| r["position"] }).to eq((26..40).to_a)
  end

  describe "invalid params" do
    def expect_invalid(overrides, details)
      search(overrides)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body).to eq("error" => "invalid_params", "details" => details)
    end

    it "rejects a request with no destination" do
      expect_invalid({ dest_id: nil, dest_type: nil }, "destination" => "give dest_id with dest_type, or ss")
    end

    it "rejects a non-integer dest_id and an unknown dest_type" do
      expect_invalid({ dest_id: "abc", dest_type: "planet" },
        "dest_id" => "must be an integer",
        "dest_type" => "must be one of city, region, district, country, landmark, airport, hotel")
    end

    it "rejects an overlong ss" do
      expect_invalid({ dest_id: nil, dest_type: nil, ss: "x" * 101 }, "ss" => "must be at most 100 characters")
    end

    it "requires both dates" do
      expect_invalid({ checkin: nil, checkout: nil }, "checkin" => "is required", "checkout" => "is required")
    end

    it "rejects a date that isn't ISO" do
      expect_invalid({ checkin: "30/09/2026" }, "checkin" => "must be an ISO date (YYYY-MM-DD)")
    end

    it "rejects a checkout on or before checkin" do
      expect_invalid({ checkout: "2026-09-30" }, "checkout" => "must be after checkin")
    end

    it "rejects a checkin in the past" do
      expect_invalid({ checkin: "2026-09-24" }, "checkin" => "must not be in the past")
    end

    it "rejects out-of-range and non-integer counts" do
      expect_invalid({ adults: 0, rooms: "two", children: 11, offset: 1001 },
        "adults" => "must be between 1 and 30", "rooms" => "must be an integer",
        "children" => "must be between 0 and 10", "offset" => "must be between 0 and 1000")
    end

    it "never fetches" do
      allow(fetcher).to receive(:fetch).and_call_original
      search(checkin: nil)

      expect(fetcher).not_to have_received(:fetch)
    end
  end

  context "when the page parses to zero properties" do
    let(:responses) { [Scraper::Response.new(status: 200, headers: {}, body: "<html><body>redesigned</body></html>")] }

    it "returns 200 with empty results flagged degraded: zero_results" do
      search

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("results" => [], "degraded" => "zero_results")
    end
  end

  # Cold start then warm hit, against Booking's real AWS WAF challenge.
  context "when AWS WAF challenges the cold fast path" do
    let(:responses) { [challenge, cleared] }

    it "detects the challenge, solves, retries, and returns 200 with browser_used: true" do
      search

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["browser_used"]).to be(true)
      expect(response.parsed_body["results"].length).to eq(15)
      expect(solver.calls).to eq(1)
    end

    it "serves the next request from the cached clearance with browser_used: false" do
      search
      search(offset: 25)

      expect(response.parsed_body["browser_used"]).to be(false)
      expect(solver.calls).to eq(1)
    end
  end

  context "when the challenge persists after the solve" do
    let(:responses) { [challenge] }

    it "returns 502 retry_budget_exhausted instead of an empty 200" do
      search

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "retry_budget_exhausted")
    end
  end

  context "when the browser earns no token" do
    let(:responses) { [challenge] }

    before { allow(solver).to receive(:solve).and_raise(Scraper::SolveFailed, "FlareSolverr returned no aws-waf-token cookie") }

    it "returns 502 solve_failed" do
      search

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body).to eq("error" => "solve_failed")
    end
  end

  it "routes AWS WAF challenges to FlareSolverr in production wiring" do
    kind = Scraper::Challenge.new(kind: :aws_waf, evidence: {})

    expect(Api::V1::ScrapeController.build_clearance_store.registry.for(kind)).to be_a(Scraper::FlareSolverrSolver)
  end

  it "wires the real curl-impersonate fetcher with the site's profile" do
    search

    expect(Scraper::CurlImpersonateFetcher).to have_received(:new).with(hash_including(profile: :chrome146))
  end

  it "streams the same flow as Server-Sent Events when asked" do
    search(stream: "true")

    expect(response.media_type).to eq("text/event-stream")
    expect(response.body).to include("event: done")
  end
end
