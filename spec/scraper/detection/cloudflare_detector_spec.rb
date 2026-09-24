require "rails_helper"

# CloudflareDetector recognises the "Just a moment…" challenge from any one of
# its markers and returns a typed Challenge; a clean 200 returns nil.
RSpec.describe Scraper::CloudflareDetector do
  subject(:detector) { described_class.new }

  def response(status: 200, headers: {}, body: "")
    Scraper::Response.new(status: status, headers: headers, body: body)
  end

  it "flags a 403 challenge status" do
    challenge = detector.detect(response(status: 403))

    expect(challenge.kind).to eq(:cloudflare_js)
    expect(challenge.evidence).to eq(status: 403)
  end

  it "flags a 503 challenge status" do
    expect(detector.detect(response(status: 503)).kind).to eq(:cloudflare_js)
  end

  it "flags the cf-mitigated: challenge header regardless of casing" do
    challenge = detector.detect(response(headers: { "CF-Mitigated" => "challenge" }))

    expect(challenge.kind).to eq(:cloudflare_js)
    expect(challenge.evidence).to eq(header: "cf-mitigated")
  end

  it "flags a 'Just a moment' body marker on a 200" do
    challenge = detector.detect(response(body: "<title>Just a moment...</title>"))

    expect(challenge.kind).to eq(:cloudflare_js)
    expect(challenge.evidence).to eq(body: "Just a moment")
  end

  it "flags the challenge-platform body marker" do
    body = %(<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/jsch/v1"></script>)
    expect(detector.detect(response(body: body)).kind).to eq(:cloudflare_js)
  end

  it "returns nil for a clean 200 with no markers" do
    expect(detector.detect(response(status: 200, body: "<ol class='products'></ol>"))).to be_nil
  end
end
