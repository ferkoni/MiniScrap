module Scraper
  # Interface for the cheap HTTP fast path. Implementations return a Response
  # and never raise on non-2xx — detection inspects the Response instead.
  #
  #   fetch(url, ua:, cookies:, headers:) -> Response
  #
  # Impls: CurlImpersonateFetcher (production, arrives in a later slice) and
  # FakeFetcher (the spec/dev injection seam).
  module Fetcher
    def fetch(_url, ua: nil, cookies: {}, headers: {})
      raise NotImplementedError, "#{self.class} must implement #fetch"
    end
  end
end
