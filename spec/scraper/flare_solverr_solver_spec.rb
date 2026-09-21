require "rails_helper"

# The one class that touches a real browser, asserted against a WebMock'd
# FlareSolverr — no Docker, no network. Response shapes mirror a real solve
# against nissei (FlareSolverr 3.5.2).
RSpec.describe Scraper::FlareSolverrSolver do
  let(:endpoint) { "http://flaresolverr.test:8191/v1" }
  let(:url) { "https://nissei.com/py/catalogsearch/result/?q=ps5" }
  let(:challenge) { Scraper::Challenge.new(kind: :cloudflare_js, evidence: { status: 403 }) }
  let(:now) { Time.utc(2026, 9, 21, 12, 0, 0) }
  let(:ua) { "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36" }

  subject(:solver) { described_class.new(base_url: "http://flaresolverr.test:8191", timeout: 60, ttl: 1800, clock: -> { now }) }

  let(:cookies) do
    [
      { "name" => "cf_clearance", "value" => "cleared", "domain" => ".nissei.com", "expiry" => (now + 365 * 86_400).to_i },
      { "name" => "PHPSESSID", "value" => "sess", "domain" => ".nissei.com" }
    ]
  end

  def flaresolverr_replies(body, status: 200)
    stub_request(:post, endpoint).to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def solved(cookies: self.cookies)
    { "status" => "ok", "message" => "Challenge solved!", "solution" => { "url" => url, "status" => 200, "cookies" => cookies, "userAgent" => ua, "response" => "<html>…</html>" } }
  end

  context "when FlareSolverr clears the challenge" do
    before { flaresolverr_replies(solved) }

    it "POSTs the documented request.get command with the solve deadline in ms" do
      solver.solve(url, challenge)

      expect(WebMock).to have_requested(:post, endpoint)
        .with(body: { cmd: "request.get", url: url, maxTimeout: 60_000 }, headers: { "Content-Type" => "application/json" })
    end

    it "packs every returned cookie and the browser's exact UA into a Clearance" do
      clearance = solver.solve(url, challenge)

      expect(clearance.cookies).to eq("cf_clearance" => "cleared", "PHPSESSID" => "sess")
      expect(clearance.ua).to eq(ua)
      expect(clearance.headers).to eq({})
    end

    # The cookie's own expiry is far longer than Cloudflare honours the
    # clearance for, so the TTL caps it; early death is still handled reactively.
    it "caps the clearance's lifetime at the TTL" do
      expect(solver.solve(url, challenge).expires_at).to eq(now + 1800)
    end
  end

  context "when the cf_clearance cookie expires before the TTL" do
    let(:cookies) { [{ "name" => "cf_clearance", "value" => "cleared", "expiry" => (now + 600).to_i }] }

    before { flaresolverr_replies(solved) }

    it "expires with the cookie" do
      expect(solver.solve(url, challenge).expires_at).to eq(now + 600)
    end
  end

  # A 200 with the challenge still in place: FlareSolverr "succeeded" but no
  # clearance came back, which must not be cached as one.
  context "when the solve returns without a cf_clearance cookie" do
    before { flaresolverr_replies(solved(cookies: [{ "name" => "PHPSESSID", "value" => "sess" }])) }

    it "raises SolveFailed" do
      expect { solver.solve(url, challenge) }.to raise_error(Scraper::SolveFailed, /cf_clearance/)
    end
  end

  context "when FlareSolverr reports its own solve timeout" do
    before do
      flaresolverr_replies({ "status" => "error", "message" => "Error: Error solving the challenge. Timeout after 60.0 seconds." }, status: 500)
    end

    it "raises SolveTimeout" do
      expect { solver.solve(url, challenge) }.to raise_error(Scraper::SolveTimeout, /Timeout after 60/)
    end
  end

  context "when FlareSolverr reports any other error" do
    before { flaresolverr_replies({ "status" => "error", "message" => "Error: net::ERR_NAME_NOT_RESOLVED" }, status: 500) }

    it "raises SolveFailed with its message" do
      expect { solver.solve(url, challenge) }.to raise_error(Scraper::SolveFailed, /ERR_NAME_NOT_RESOLVED/)
    end
  end

  context "when the HTTP read outlives the deadline" do
    before { stub_request(:post, endpoint).to_raise(Net::ReadTimeout) }

    it "raises SolveTimeout rather than blocking" do
      expect { solver.solve(url, challenge) }.to raise_error(Scraper::SolveTimeout)
    end
  end

  context "when FlareSolverr is unreachable" do
    before { stub_request(:post, endpoint).to_raise(Errno::ECONNREFUSED) }

    it "raises SolveFailed" do
      expect { solver.solve(url, challenge) }.to raise_error(Scraper::SolveFailed, /Connection refused/)
    end
  end

  context "when FlareSolverr answers with something that isn't JSON" do
    before { stub_request(:post, endpoint).to_return(status: 502, body: "<html>Bad Gateway</html>") }

    it "raises SolveFailed" do
      expect { solver.solve(url, challenge) }.to raise_error(Scraper::SolveFailed)
    end
  end
end
