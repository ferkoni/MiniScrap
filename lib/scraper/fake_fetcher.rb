module Scraper
  # A Fetcher that returns a canned Response instead of doing real HTTP — no
  # network, no subprocess. Two roles:
  #
  #   * the spec injection seam (build it with the body/Response you want), and
  #   * the slice-1 walking-skeleton default in ScrapeController, so the endpoint
  #     is demoable end-to-end before the real fetcher exists. Slice #5 swaps the
  #     production default for CurlImpersonateFetcher; FakeFetcher then stays a
  #     test-only seam.
  class FakeFetcher
    include Fetcher

    def initialize(response: nil, body: nil, status: 200, headers: {})
      @response = response || Response.new(status:, headers:, body: body || DEFAULT_BODY)
    end

    def fetch(_url, ua: nil, cookies: {}, headers: {})
      @response
    end

    # A minimal synthetic product listing so the walking-skeleton endpoint
    # returns a non-empty result when curled with no fixture injected.
    DEFAULT_BODY = <<~HTML.freeze
      <ol class="products">
        <li class="product-item">
          <a class="product-item-link" href="https://nissei.com/py/product/sample">Sample Product</a>
          <span class="price">Gs. 1.000.000</span>
          <div class="stock available">En stock</div>
        </li>
      </ol>
    HTML
  end
end
