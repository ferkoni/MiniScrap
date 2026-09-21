# GET /ready — whether this instance can actually scrape: the curl-impersonate
# binary is present and runnable, and the FlareSolverr service answers. 200
# when both hold, 503 otherwise, naming each check.
#
# /up stays the liveness check kamal-proxy gates deploys on: a FlareSolverr
# outage should show up here (and in monitoring), not block a deploy.
class ReadinessController < ApplicationController
  def show
    checks = {
      curl_impersonate: Scraper::CurlImpersonateFetcher.new(
        profile: Api::V1::NisseiController.site.profile,
        bin_dir: Api::V1::ScrapeController::CURL_IMPERSONATE_DIR
      ).ready?,
      flaresolverr: Scraper::FlareSolverrSolver.new(base_url: Api::V1::ScrapeController::FLARESOLVERR_URL).ready?
    }
    ready = checks.values.all?

    render json: { status: ready ? "ready" : "not_ready", checks: checks },
           status: ready ? :ok : :service_unavailable
  end
end
