module Scraper
  # Interface for the cheap HTTP fast path. Implementations return a Response
  # and never raise on non-2xx — detection inspects the Response instead.
  #
  #   fetch(url, ua:, cookies:, headers:, proxy:) -> Response
  #
  # Impls: CurlImpersonateFetcher (production) and FakeFetcher (the spec
  # injection seam). Raises FetchFailed only when there is no response at all.
  module Fetcher
    def fetch(_url, ua: nil, cookies: {}, headers: {}, proxy: nil)
      raise NotImplementedError, "#{self.class} must implement #fetch"
    end
  end
end
