module Scraper
  # The cached result of an expensive solve: whatever the fast path must replay
  # to stay cleared. A generic bag — `cookies` (e.g. { "cf_clearance" => … }),
  # any solver-specific replay `headers`, and the exact `ua` the solving browser
  # used — so another protection's artifacts replay through the same fast path
  # with no per-site branching. The UA travels with the cookies because the
  # clearance is bound to it; `expires_at` is when the store stops serving it.
  Clearance = Data.define(:cookies, :headers, :ua, :expires_at) do
    def valid_at?(time)
      time < expires_at
    end
  end
end
