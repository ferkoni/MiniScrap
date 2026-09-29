module Scraper
  # A Fetcher that returns canned Responses instead of doing real HTTP — no
  # network, no subprocess. The spec injection seam: build it with the
  # body/Response you want, or a `responses:` sequence to script a
  # challenge-then-cleared exchange. Production uses CurlImpersonateFetcher.
  # Every fetch is recorded in `requests`, in order, for specs to inspect.
  class FakeFetcher
    include Fetcher

    attr_reader :requests

    def initialize(response: nil, responses: nil, body: nil, status: 200, headers: {})
      @responses = responses&.dup || [response || Response.new(status:, headers:, body: body.to_s)]
      @requests = []
    end

    # Serves the responses in order; the last one repeats for any further fetch.
    # A response that is an exception is raised instead (e.g. FetchFailed).
    def fetch(url, ua: nil, cookies: {}, headers: {}, proxy: nil)
      @requests << { url:, ua:, cookies:, headers:, proxy: }
      response = @responses.size > 1 ? @responses.shift : @responses.first
      raise response if response.is_a?(Exception)

      response
    end
  end
end
