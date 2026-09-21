module Api
  module V1
    # Abstract parent: the only Rails-aware part of the scraping path. It owns
    # the `scrapes` class-level DSL (declares the one Site, stored at boot) and
    # the reusable `scrape(path)` helper — build a ScrapeFlow for a
    # controller-built path, run it, render the returned ScrapeResult as JSON.
    # Per-site children declare their Site and add one action per endpoint.
    class ScrapeController < ApplicationController
      class_attribute :site, instance_accessor: false

      # The one ClearanceStore for the whole process, shared by every site
      # controller and every request so a solved clearance outlives the request
      # that solved it (a store per request would re-solve every time). Its
      # registry routes :cloudflare_js to the StubSolver until slice #6 wires
      # FlareSolverrSolver.
      class_attribute :clearance_store, instance_accessor: false, default: Scraper::ClearanceStore.new(
        registry: Scraper::SolverRegistry.new(cloudflare_js: Scraper::StubSolver.new)
      )

      # Flow error -> HTTP status. This is the edge's single source of truth for
      # mapping raised Scraper::Errors onto responses; later slices add their
      # entries here (SolveFailed -> 502, SolveTimeout -> 504) without touching
      # the Rails-free core.
      ERROR_STATUS = {
        Scraper::UnsupportedChallenge => :not_implemented,
        Scraper::RetryBudgetExhausted => :bad_gateway
      }.freeze

      rescue_from Scraper::Error do |error|
        render json: error_body(error), status: ERROR_STATUS.fetch(error.class, :internal_server_error)
      end

      # Class-level DSL: declares the one Site this controller scrapes.
      def self.scrapes(id, base_url:, profile:, parser:)
        self.site = Scraper::Site.new(
          id: id,
          base_url: base_url,
          profile: profile,
          parser: parser
        )
      end

      private

      # Reusable edge helper: run the flow for a controller-built, site-relative
      # path and render the result. Raised Scraper::Errors are mapped to status
      # codes by the rescue_from above.
      def scrape(path)
        result = Scraper::ScrapeFlow.new(
          site: self.class.site,
          fetcher: fetcher,
          detector: Scraper::CompositeDetector.new(detectors),
          store: store
        ).run(path)
        render json: serialize(result)
      end

      # Overridable wiring hook. The slice-1 walking skeleton defaults to a
      # demoable FakeFetcher; slice #5 swaps this for the real
      # Scraper::CurlImpersonateFetcher in production wiring.
      def fetcher
        Scraper::FakeFetcher.new
      end

      # Overridable wiring hook: the ordered detector list, wrapped into a
      # CompositeDetector for the flow. A site facing an additional protection
      # extends it with `def detectors = super + [...]` rather than editing
      # the flow.
      def detectors
        [Scraper::CloudflareDetector.new]
      end

      # Overridable wiring hook: the shared, process-wide ClearanceStore. Never
      # build one here — it must outlive the request.
      def store
        self.class.clearance_store
      end

      def serialize(result)
        {
          site: result.site,
          results: result.results.map(&:to_h),
          browser_used: result.browser_used,
          latency_ms: result.latency_ms,
          degraded: result.degraded
        }
      end

      # Error payload: a snake_case tag derived from the error class, plus the
      # challenge `kind` when the error carries one (e.g. UnsupportedChallenge
      # -> { error: "unsupported_challenge", kind: "cloudflare_js" }).
      def error_body(error)
        body = { error: error.class.name.demodulize.underscore }
        body[:kind] = error.kind if error.respond_to?(:kind)
        body
      end
    end
  end
end
