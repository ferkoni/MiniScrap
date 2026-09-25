require "rails_helper"

# The whole thesis, for real: a browser solve via FlareSolverr yields a
# clearance that the curl-impersonate fast path replays to get the real page.
# Excluded by default and from CI. Needs FlareSolverr (FLARESOLVERR_URL,
# default http://localhost:8191) and curl-impersonate (CURL_IMPERSONATE_DIR):
#
#   docker run -d --name flaresolverr -p 8191:8191 ghcr.io/flaresolverr/flaresolverr:latest
#   LIVE=1 bundle exec rspec spec/live/flare_solverr_solver_spec.rb
#
# One solve + one fetch against nissei per run — keep it rare. On success it
# refreshes the captured fixture spec/fixtures/nissei/results.html.
RSpec.describe Scraper::FlareSolverrSolver, :live do
  let(:url) { "https://nissei.com/py/catalogsearch/result/?q=ps5" }
  let(:challenge) { Scraper::Challenge.new(kind: :cloudflare_js, evidence: {}) }
  let(:solver) { described_class.new(base_url: ENV.fetch("FLARESOLVERR_URL", "http://localhost:8191")) }
  let(:fetcher) do
    Scraper::CurlImpersonateFetcher.new(profile: :chrome146, bin_dir: ENV.fetch("CURL_IMPERSONATE_DIR", File.expand_path("~/curl-impersonate")))
  end

  it "solves nissei's challenge into a clearance the fast path can replay" do
    clearance = solver.solve(url, challenge)
    expect(clearance.cookies).to include("cf_clearance")
    expect(clearance.ua).to match(%r{Chrome/\d+})

    response = fetcher.fetch(url, ua: clearance.ua, cookies: clearance.cookies, headers: clearance.headers)
    expect(Scraper::CloudflareDetector.new.detect(response)).to be_nil
    expect(response.status).to eq(200)
    expect(response.body).to include("product-item-link")

    Rails.root.join("spec/fixtures/nissei/results.html").write(response.body)
  end
end
