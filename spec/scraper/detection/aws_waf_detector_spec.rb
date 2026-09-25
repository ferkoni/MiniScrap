require "rails_helper"

# AwsWafDetector against Booking's real challenge and results pages, plus the
# header AWS documents (which Booking doesn't send today).
RSpec.describe Scraper::AwsWafDetector do
  subject(:detector) { described_class.new }

  let(:challenge_page) { Rails.root.join("spec/fixtures/booking/challenge.html").read }
  let(:results_page) { Rails.root.join("spec/fixtures/booking/search.html").read }

  def response(status: 200, headers: {}, body: "")
    Scraper::Response.new(status: status, headers: headers, body: body)
  end

  it "flags Booking's real challenge: a 202 with a challenge-only marker" do
    challenge = detector.detect(response(status: 202, headers: { "content-type" => "text/html" }, body: challenge_page))

    expect(challenge.kind).to eq(:aws_waf)
    expect(challenge.evidence).to eq(status: 202, body: 'id="challenge-container"')
  end

  it "flags the challenge by its script path when the container is renamed" do
    body = challenge_page.sub('id="challenge-container"', 'id="renamed"')

    expect(detector.detect(response(status: 202, body: body)).evidence).to eq(status: 202, body: "/__challenge_")
  end

  it "flags AWS's documented x-amzn-waf-action header on any status, regardless of casing" do
    challenge = detector.detect(response(status: 405, headers: { "X-Amzn-Waf-Action" => "challenge" }))

    expect(challenge.kind).to eq(:aws_waf)
    expect(challenge.evidence).to eq(header: "x-amzn-waf-action", action: "challenge")
  end

  it "records a visible CAPTCHA in the evidence" do
    expect(detector.detect(response(status: 405, headers: { "x-amzn-waf-action" => "CAPTCHA" })).evidence)
      .to include(action: "captcha")
  end

  it "ignores a 202 without a challenge marker" do
    expect(detector.detect(response(status: 202, body: "<html>accepted</html>"))).to be_nil
  end

  # Real pages load challenge.js in the background to refresh the token.
  it "ignores the real results page, which mentions challenge.js" do
    expect(results_page).to include("challenge.js")
    expect(detector.detect(response(body: results_page))).to be_nil
  end

  it "ignores the real results page even if served with a 202" do
    expect(detector.detect(response(status: 202, body: results_page))).to be_nil
  end

  # Each detector owns one protection.
  it "ignores Cloudflare's challenge" do
    expect(detector.detect(response(status: 403, headers: { "cf-mitigated" => "challenge" }, body: "Just a moment..."))).to be_nil
  end

  it "keeps Cloudflare's detector blind to Booking's challenge" do
    expect(Scraper::CloudflareDetector.new.detect(response(status: 202, body: challenge_page))).to be_nil
  end
end
