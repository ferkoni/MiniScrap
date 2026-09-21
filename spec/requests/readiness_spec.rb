require "rails_helper"

# GET /ready — can this instance actually scrape? Unlike /up (liveness, used
# by kamal-proxy to gate deploys), it checks the two external dependencies.
RSpec.describe "GET /ready", type: :request do
  let(:fetcher) { instance_double(Scraper::CurlImpersonateFetcher, ready?: true) }
  let(:solver) { instance_double(Scraper::FlareSolverrSolver, ready?: true) }

  before do
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(fetcher)
    allow(Scraper::FlareSolverrSolver).to receive(:new).and_return(solver)
  end

  it "is 200 ready when curl-impersonate and FlareSolverr are both usable" do
    get "/ready"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("status" => "ready", "checks" => { "curl_impersonate" => true, "flaresolverr" => true })
  end

  it "checks the configured binary directory and FlareSolverr URL" do
    get "/ready"

    expect(Scraper::CurlImpersonateFetcher).to have_received(:new).with(hash_including(bin_dir: Api::V1::ScrapeController::CURL_IMPERSONATE_DIR))
    expect(Scraper::FlareSolverrSolver).to have_received(:new).with(hash_including(base_url: Api::V1::ScrapeController::FLARESOLVERR_URL))
  end

  context "when FlareSolverr is down" do
    let(:solver) { instance_double(Scraper::FlareSolverrSolver, ready?: false) }

    it "is 503 not_ready, naming the failing check" do
      get "/ready"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to eq("status" => "not_ready", "checks" => { "curl_impersonate" => true, "flaresolverr" => false })
    end
  end

  context "when the curl-impersonate binary is missing" do
    let(:fetcher) { instance_double(Scraper::CurlImpersonateFetcher, ready?: false) }

    it "is 503 not_ready" do
      get "/ready"

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body["checks"]).to include("curl_impersonate" => false)
    end
  end
end
