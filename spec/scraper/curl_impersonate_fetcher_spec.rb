require "rails_helper"

# The real fast path, asserted without spawning curl: a fake runner records the
# argv it was handed and replays canned curl output. (WebMock can't see a
# subprocess, so the runner is the seam.)
RSpec.describe Scraper::CurlImpersonateFetcher do
  let(:url) { "https://nissei.com/py/search?q=ps5" }
  let(:meta) { described_class::META }

  # Canned curl stdout: body, then our write-out trailer (status + header JSON).
  def curl_output(status: 200, headers: { "content-type" => ["text/html"] }, body: "<html>ok</html>")
    "#{body}#{meta}#{status}#{meta}#{headers.to_json}"
  end

  let(:output) { curl_output }
  let(:exitstatus) { 0 }
  let(:stderr) { "" }
  let(:calls) { [] }
  let(:runner) do
    lambda do |argv, timeout:|
      calls << { argv: argv, timeout: timeout }
      Scraper::Subprocess::Result.new(stdout: output, stderr: stderr, exitstatus: exitstatus)
    end
  end

  let(:fetcher) { described_class.new(profile: :chrome131, bin_dir: "/opt/curl-impersonate", timeout: 20, runner: runner) }

  def argv
    calls.last[:argv]
  end

  # The value following a flag in the recorded argv.
  def flag(name)
    argv[argv.index(name) + 1]
  end

  describe "the curl invocation" do
    before { fetcher.fetch(url, ua: "SOLVER-UA", cookies: { "cf_clearance" => "abc", "x" => "1" }, headers: { "X-Extra" => "1" }) }

    it "runs the curl-impersonate binary impersonating the site's profile" do
      expect(argv.first).to eq("/opt/curl-impersonate/curl-impersonate")
      expect(flag("--impersonate")).to eq("chrome131")
    end

    # -H replaces the profile's own User-Agent in place (keeping Chrome's header
    # order) — unlike the curl_chrome* wrappers, which would send two.
    it "presents the clearance's UA as the User-Agent header" do
      expect(argv).to include("-H", "User-Agent: SOLVER-UA")
    end

    it "presents the clearance's cookies" do
      expect(flag("--cookie")).to eq("cf_clearance=abc; x=1")
    end

    it "passes any extra replay headers" do
      expect(argv).to include("X-Extra: 1")
    end

    it "bounds the transfer with curl's own timeout and a slightly longer hard kill" do
      expect(flag("--max-time")).to eq("20")
      expect(calls.last[:timeout]).to be > 20
    end

    it "follows a bounded number of redirects" do
      expect(argv).to include("--location")
      expect(flag("--max-redirs")).to eq("5")
    end

    it "asks for the body and a status + headers trailer on stdout" do
      expect(flag("--write-out")).to eq("#{meta}%{response_code}#{meta}%{header_json}")
    end

    it "ends with the url" do
      expect(argv.last).to eq(url)
    end
  end

  it "sends no User-Agent or cookie flags when there is no clearance, leaving the profile's own" do
    fetcher.fetch(url)

    expect(argv.grep(/\AUser-Agent:/)).to be_empty
    expect(argv).not_to include("--cookie")
  end

  describe "the returned Response" do
    let(:output) do
      curl_output(status: 403, headers: { "cf-mitigated" => ["challenge"], "set-cookie" => ["a=1", "b=2"] }, body: "Just a moment...")
    end

    subject(:response) { fetcher.fetch(url) }

    it "carries the status, body, and headers of the final response" do
      expect(response).to eq(
        Scraper::Response.new(
          status: 403,
          headers: { "cf-mitigated" => "challenge", "set-cookie" => "a=1, b=2" },
          body: "Just a moment..."
        )
      )
    end

    it "is inspectable by the challenge detector" do
      expect(Scraper::CloudflareDetector.new.detect(response).kind).to eq(:cloudflare_js)
    end

    context "with an empty body" do
      let(:output) { curl_output(status: 503, headers: {}, body: "") }

      it "is still well-formed" do
        expect(response).to have_attributes(status: 503, headers: {}, body: "")
      end
    end
  end

  context "when curl exits non-zero (DNS, TLS, connection, or its own timeout)" do
    let(:exitstatus) { 28 }
    let(:stderr) { "curl: (28) Operation timed out after 20001 milliseconds\n" }
    let(:output) { "" }

    it "raises FetchFailed carrying curl's error" do
      expect { fetcher.fetch(url) }.to raise_error(Scraper::FetchFailed, /Operation timed out/)
    end
  end

  context "when the curl-impersonate binary is missing" do
    let(:runner) { ->(_argv, timeout:) { raise Errno::ENOENT, "/opt/curl-impersonate/curl-impersonate" } }

    it "raises FetchFailed pointing at CURL_IMPERSONATE_DIR, not a bare 500" do
      expect { fetcher.fetch(url) }.to raise_error(Scraper::FetchFailed, /CURL_IMPERSONATE_DIR/)
    end
  end

  context "when the process has to be killed" do
    let(:runner) { ->(_argv, timeout:) { raise Scraper::Subprocess::TimedOut, "killed after #{timeout}s" } }

    it "surfaces a FetchFailed, not a hang" do
      expect { fetcher.fetch(url) }.to raise_error(Scraper::FetchFailed, /killed/)
    end
  end

  # Readiness, for GET /ready: is the binary there and runnable? No request.
  describe "#ready?" do
    it "is true when the curl-impersonate binary is executable" do
      Dir.mktmpdir do |dir|
        binary = File.join(dir, "curl-impersonate")
        File.write(binary, "#!/bin/sh\n")
        File.chmod(0o755, binary)

        expect(described_class.new(profile: :chrome146, bin_dir: dir).ready?).to be(true)
      end
    end

    it "is false when the binary is missing" do
      expect(described_class.new(profile: :chrome146, bin_dir: "/nonexistent").ready?).to be(false)
    end
  end
end
