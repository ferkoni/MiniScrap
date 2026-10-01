module Api
  module V1
    # Abstract parent: the only Rails-aware part of the scraping path. It owns
    # the `scrapes` class-level DSL (declares the one Site, stored at boot) and
    # the reusable `scrape(path)` helper — build a ScrapeFlow for a
    # controller-built path, run it, render the returned ScrapeResult as JSON.
    # Per-site children declare their Site and add one action per endpoint.
    class ScrapeController < ApplicationController
      # Lets a request opt into Server-Sent Events (see #stream_scrape). A plain
      # JSON request renders exactly as before.
      include ActionController::Live

      class_attribute :site, instance_accessor: false

      # Where the FlareSolverr service (the slow path's browser) listens.
      FLARESOLVERR_URL = ENV.fetch("FLARESOLVERR_URL", "http://localhost:8191")

      # The production store: Cloudflare and AWS WAF challenges routed to
      # FlareSolverr, one solver per protection (AWS WAF: see AwsWafDetector);
      # background refresh-ahead solves report to the Rails log. With
      # REDIS_URL the cache and its single-flight lock are shared by every
      # process (so Puma may run workers, and several hosts may share it);
      # without, they live in this process's memory. SCRAPER_MAX_SOLVES caps
      # the browser solves this process runs at once; past it, a request that
      # needs a solve gets a 503 at once instead of holding a thread.
      def self.build_clearance_store(redis_url: ENV["REDIS_URL"], max_solves: Integer(ENV.fetch("SCRAPER_MAX_SOLVES", "2"), 10))
        backend = if redis_url
          Scraper::ClearanceStore::RedisBackend.new(redis: Redis.new(url: redis_url))
        else
          Scraper::ClearanceStore::MemoryBackend.new
        end

        Scraper::ClearanceStore.new(
          registry: Scraper::SolverRegistry.new(
            cloudflare_js: Scraper::FlareSolverrSolver.new(base_url: FLARESOLVERR_URL),
            # FlareSolverr doesn't recognise AWS WAF's challenge, so the browser
            # is kept running for challenge.js to earn its token. AWS WAF honours
            # a solve for 300 s by default, far less than the cookie's own expiry.
            aws_waf: Scraper::FlareSolverrSolver.new(
              base_url: FLARESOLVERR_URL, clearance_cookie: "aws-waf-token", wait: 10, ttl: 300
            )
          ),
          backend: backend,
          logger: Rails.logger,
          max_solves: max_solves
        )
      end

      # The one ClearanceStore for the whole process, shared by every site
      # controller and every request so a solved clearance outlives the request
      # that solved it (a store per request would re-solve every time).
      class_attribute :clearance_store, instance_accessor: false, default: build_clearance_store

      # Egress proxies, round-robin per request (SCRAPER_PROXIES, comma-
      # separated). Each gets its own clearance. Empty: the host's own IP.
      class_attribute :proxy_pool, instance_accessor: false, default: Scraper::ProxyPool.parse(ENV["SCRAPER_PROXIES"])

      # Where the curl-impersonate binary lives (lexiforest build).
      CURL_IMPERSONATE_DIR = ENV.fetch("CURL_IMPERSONATE_DIR") { File.expand_path("~/curl-impersonate") }

      # Flow error -> HTTP status. This is the edge's single source of truth for
      # mapping raised Scraper::Errors onto responses; a new error is a new
      # entry here, never a change to the Rails-free core.
      ERROR_STATUS = {
        Scraper::UnsupportedChallenge => :not_implemented,
        Scraper::SolverBusy => :service_unavailable,
        Scraper::RetryBudgetExhausted => :bad_gateway,
        Scraper::FetchFailed => :bad_gateway,
        Scraper::SolveFailed => :bad_gateway,
        Scraper::SolveTimeout => :gateway_timeout
      }.freeze

      rescue_from Scraper::Error do |error|
        render json: error_body(error), status: ERROR_STATUS.fetch(error.class, :internal_server_error)
      end

      # Raised by an action whose typed params don't validate; `details` maps
      # each bad param to what's wrong with it. Rendered as a 400 before any
      # fetch happens.
      class InvalidParams < StandardError
        attr_reader :details

        def initialize(details)
          @details = details
          super("invalid params: #{details.keys.join(", ")}")
        end
      end

      rescue_from InvalidParams do |error|
        render json: { error: "invalid_params", details: error.details }, status: :bad_request
      end

      # Class-level DSL: declares the one Site this controller scrapes, the
      # identity every one of its endpoints shares (and so one clearance). How
      # each page is read is per action: see `scrape`.
      def self.scrapes(id, base_url:, profile:)
        self.site = Scraper::Site.new(id: id, base_url: base_url, profile: profile)
      end

      private

      # Reusable edge helper: run the flow for a controller-built, site-relative
      # path and render the result — one JSON body by default, or a live event
      # stream when the client asks for one. Raised Scraper::Errors are mapped
      # to status codes by the rescue_from above. Each action names how its
      # page is read: the `parser`, and the `contract` its output must meet
      # (see Scraper::Coverage).
      def scrape(path, parser:, contract:)
        return stream_scrape(path, parser: parser, contract: contract) if stream?

        render json: serialize(run_flow(path, parser: parser, contract: contract))
      end

      def run_flow(path, parser:, contract:, events: Scraper::NullEventSink.new)
        Scraper::ScrapeFlow.new(
          site: self.class.site,
          parser: parser,
          contract: contract,
          fetcher: fetcher,
          detector: Scraper::CompositeDetector.new(detectors),
          store: store,
          events: events,
          proxy: self.class.proxy_pool.next
        ).run(path)
      end

      def stream?
        params[:stream] == "true" || request.headers["Accept"].to_s.include?("text/event-stream")
      end

      # The live-SSE variant: the flow narrates fast_path / solving as it
      # happens, then the returned result goes out as a final `done` event
      # carrying the same body as the JSON endpoint. Headers (and a 200) are
      # already sent by then, so a failure becomes a terminal `error` event
      # carrying the status the JSON endpoint would have used.
      def stream_scrape(path, parser:, contract:)
        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        sink = Scraper::SseEventSink.new(response.stream)
        sink.emit(:done, serialize(run_flow(path, parser: parser, contract: contract, events: sink)))
      rescue Scraper::Error => error
        status = Rack::Utils.status_code(ERROR_STATUS.fetch(error.class, :internal_server_error))
        sink.emit(:error, error_body(error).merge(status: status))
      ensure
        response.stream.close
      end

      # Overridable wiring hook: the real curl-impersonate fast path,
      # impersonating the site's profile. Specs stub this construction point
      # with a FakeFetcher.
      def fetcher
        Scraper::CurlImpersonateFetcher.new(profile: self.class.site.profile, bin_dir: CURL_IMPERSONATE_DIR)
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

      # `filters` appears only for a page that offers them (e.g. search): the
      # parser's data carries it only then.
      def serialize(result)
        {
          site: result.site,
          **result.data,
          browser_used: result.browser_used,
          latency_ms: result.latency_ms,
          coverage: result.coverage,
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
