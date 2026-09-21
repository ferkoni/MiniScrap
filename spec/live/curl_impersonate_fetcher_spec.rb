require "rails_helper"

# Real network, real curl-impersonate binary — excluded by default and from CI.
# Run with: LIVE=1 bundle exec rspec spec/live
# Needs curl-impersonate in CURL_IMPERSONATE_DIR (default ~/curl-impersonate).
RSpec.describe Scraper::CurlImpersonateFetcher, :live do
  subject(:fetcher) do
    described_class.new(profile: :chrome131, bin_dir: ENV.fetch("CURL_IMPERSONATE_DIR", File.expand_path("~/curl-impersonate")))
  end

  it "performs a real fetch and returns a populated Response" do
    response = fetcher.fetch("https://example.com/")

    expect(response.status).to eq(200)
    expect(response.headers).to include("content-type" => a_string_including("text/html"))
    expect(response.body).to include("Example Domain")
  end
end
