module Scraper
  # A Fetcher that returns canned Responses instead of doing real HTTP — no
  # network, no subprocess. The spec injection seam: build it with the
  # body/Response you want, or a `responses:` sequence to script a
  # challenge-then-cleared exchange. Production uses CurlImpersonateFetcher.
  class FakeFetcher
    include Fetcher

    def initialize(response: nil, responses: nil, body: nil, status: 200, headers: {})
      @responses = responses&.dup || [response || Response.new(status:, headers:, body: body.to_s)]
    end

    # Serves the responses in order; the last one repeats for any further fetch.
    def fetch(_url, ua: nil, cookies: {}, headers: {}, proxy: nil)
      @responses.size > 1 ? @responses.shift : @responses.first
    end
  end
end
