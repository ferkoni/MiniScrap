# MiniScrap: solve Cloudflare once, scrape cheaply after

MiniScrap is a small Rails API that returns clean JSON search results from
[nissei.com](https://nissei.com/py/), a real Paraguayan e-commerce site behind **Cloudflare's
managed challenge**. The interesting part isn't the scraping. It's getting in: how to beat a
challenge that needs a real browser **without** putting a browser on every request.

```
GET /api/v1/nissei/search?q=ps5
```
```jsonc
{ "site": "nissei",
  "results": [ { "title": "Juego PS5 Saros", "price": "Gs. 520.000",
                 "availability": "in_stock", "url": "https://nissei.com/py/juego-ps5-saros",
                 "position": 1 }, … ],
  "browser_used": true, "latency_ms": 13893, "degraded": null }
```

Measured against the live site: the **first** request pays one browser solve (~14s, `browser_used:
true`). **Every request after that** reuses the result over plain HTTP (~3s, `browser_used: false`).

---

## 1. The problem: HTTP alone can't get in

nissei answers anything that isn't a browser with Cloudflare's "Just a moment…" interstitial: a
`403` with `cf-mitigated: challenge`. I tried progressively more convincing clients:

| Client | Result |
|---|---|
| Ruby `Net::HTTP` | `403` challenge (wrong TLS fingerprint, instant tell) |
| [curl-impersonate](https://github.com/lexiforest/curl-impersonate) as Chrome 131 / 146 (real Chrome TLS + HTTP/2 fingerprint and headers) | **still `403`** |
| A real headless Chrome that runs the challenge JavaScript | `200` + a `cf_clearance` cookie |

TLS impersonation is **necessary but not sufficient**. This is an *active* challenge: it has to
execute JavaScript, and only a browser does that.

## 2. The insight: the browser's output is a cookie, and cookies can be cached

A browser solve is slow (10–40s) and memory-hungry. What it *produces* is small: a `cf_clearance`
cookie. So MiniScrap treats the browser as an **expensive function whose result is cached**:

```
request ─► FAST PATH: curl-impersonate + cached clearance (if any)
              ├─ 200 ─────────────────────────────────────────► parse, done   (the common case)
              └─ challenged ─► SLOW PATH: FlareSolverr (headless Chrome) solves once
                                 └─ cache { cookies, user-agent, expiry }
                                 └─ retry the FAST PATH with it ─► parse, done
```

The economics are **1 browser solve : N cheap requests**. The browser only runs on a cold start or
when a clearance dies, never on the hot path.

## 3. The keystone: a cookie bound to a fingerprint

`cf_clearance` isn't a bearer token. Cloudflare binds it to the client that solved it: the
**User-Agent**, the **egress IP**, the **TLS/HTTP-2 fingerprint**, and the **header set and order**.
Replaying it from a client that looks different is a `403` that looks exactly like an expired cookie.

So a `Clearance` carries the cookies **and the exact UA the browser used**, and the fast path replays
them together through a curl-impersonate profile that matches the browser. Building this surfaced two
problems that the design documents hadn't predicted:

- **The curl-impersonate wrapper scripts can't carry a foreign User-Agent.** `curl_chrome131`
  hard-codes its UA with `-H`. Adding the solver's UA sends **two** `User-Agent` headers, which is an
  obvious bot tell, and `-A` is silently ignored. The fix is to call the binary directly with
  `--impersonate chrome146`: then `-H 'User-Agent: …'` replaces the profile's UA in place and keeps
  Chrome's header order. (I checked this against a local echo server.)
- **Browser and TLS profile versions drift.** FlareSolverr 3.5.2 runs Chrome **152**, while the
  newest curl-impersonate profile is `chrome146`. nissei accepted the gap (under both `chrome131` and
  `chrome146`), but it's a real coupling, so the site uses the closest profile and the coupling is
  documented where it lives.

The cookie itself claims a lifetime of about a year, which is far longer than Cloudflare honours it.
The store caps it at 30 minutes and handles earlier death **reactively**: a `403` on a cached
clearance drops it and triggers a new solve.

## 4. The concurrency: one solve per herd

With no valid cookie, N simultaneous requests would naively launch N browsers. That's slow,
RAM-crushing, and looks like an attack. `ClearanceStore` does a **per-key single-flight** solve:

```
ps5 ────┐               ps5 leads the "nissei" flight ──► ONE browser solve
xbox ───┼─ no cookie ─► xbox, switch wait on that flight
switch ─┘               solve lands ──► all three retry the fast path with the same clearance
```

- **Per key, not global.** A short mutex guards only the bookkeeping (one `Concurrent::Promises`
  future per site); the solve itself runs outside it, so two sites solve in parallel.
- **Failure costs one attempt, not N.** If the leader's solve fails, every waiter raises the
  *leader's* error instead of promoting itself to leader, which would be a retry storm. Nothing is
  cached, so the next request after the burst starts afresh.
- **Refresh-ahead (XFetch).** The one rough edge left was a periodic cold hit: the first request
  after each expiry waits for a browser. A read of a still-valid clearance may now start **one
  background re-solve** ahead of expiry while it is served the current cookie, gated by
  XFetch (Vattani et al., *Optimal Probabilistic Cache Stampede Prevention*, VLDB 2015):
  `now + delta·beta·(−ln rand) ≥ expiry`, where `delta` is the measured solve time. That joins the
  same per-key flight, so it can never race a reactive solve. It only runs when there's demand, so
  an idle API does no solves.

These properties are tested with real threads, not by trusting a timing window. The spec helper
`GatedSolver` holds the solve open until the whole herd is parked behind it, then counts solves.
Making every caller a leader fails five of those specs.

## 5. Making the escalation observable

One JSON response hides the process, so the payload reports it: `browser_used: true` with a high
`latency_ms` is a cold start, and `false` with a low one is a cache hit. `degraded: "zero_results"`
flags a cleared page that parsed to nothing, most likely a layout the parser no longer understands,
so it can't pass for a genuinely empty search.

To watch it as it happens, ask for a stream (`Accept: text/event-stream` or `?stream=true`):

```
+0.2s   event: fast_path  {"attempt":1,"clearance":false}
+0.2s   event: solving    {"kind":"cloudflare_js"}
+14.9s  event: fast_path  {"attempt":2,"clearance":true}
+15.3s  event: done       { …the same body as the JSON endpoint… }
```

The streaming variant was added **without touching the core**. `ScrapeFlow` narrates to an injected
`EventSink` and still *returns* its result; only the edge decides whether that becomes one JSON body
or a stream.

## 6. The shape: one site today, many tomorrow

The scraping core is plain Ruby under `lib/scraper/`, and Rails only appears in the controllers.
The orchestrator names only interfaces and contains no `if site == …` or `if cloudflare`:

| Layer | Pieces |
|---|---|
| Edge (Rails) | `ScrapeController` (wiring, JSON/SSE rendering, error → status) · `NisseiController` (declares the site) |
| Orchestrator | `ScrapeFlow`: fast fetch → detect → single-flight solve → bounded retry → parse |
| Strategies | `Fetcher` (`CurlImpersonateFetcher`) · `ChallengeDetector` (`CloudflareDetector`, `CompositeDetector`) · `Solver` + `SolverRegistry` (`FlareSolverrSolver`) · `Parser` (`NisseiParser`) · `EventSink` |
| Shared state | `ClearanceStore`: the one long-lived mutable object |

| To add… | You write… | Untouched |
|---|---|---|
| a site | a ~5-line controller subclass (`scrapes "…", base_url:, profile:, parser:`) + a route | flow, store |
| a protection (e.g. DataDome) | a detector returning `Challenge(:datadome)` + one registry entry | flow, controllers |
| an endpoint | a one-line action building a path + a route | everything else |

An unrecognised protection raises `UnsupportedChallenge`, which is a `501`, rather than failing
silently. Other failures map to honest statuses: `502` for `solve_failed`, `retry_budget_exhausted`
or `fetch_failed`, and `504` for `solve_timeout`.

The parser uses **layered selectors** (a primary selector with fallbacks for every field) and emits
a source-agnostic shape (`availability` is `in_stock` / `out_of_stock` / `nil`, never nissei's
wording). A hand-made "layout-shifted" fixture renames every primary hook to prove the fallbacks
work. Checking the parser against the real page also caught a phantom result: a wishlist-sidebar
template shared the product-card class.

## 7. What I deliberately scoped out, and how I'd build it at scale

- **One process, in-memory store.** Multiple app servers would need a shared store (Redis) and a
  distributed single-flight lock, keyed by `(site, profile, egress IP)`, because a clearance is bound
  to its IP. `ClearanceKey` already has the `profile:` and `proxy:` slots.
- **One egress IP.** At scale, requests fan out over a proxy pool, and every proxy holds its own
  clearance. The same key change covers it.
- **Browsers as a pool, not a container.** One FlareSolverr is enough at this volume. At scale:
  a pool of browser workers behind a queue, sized by solve rate rather than request rate.
- **Interactive challenges.** Click-required Turnstile or reCAPTCHA can't be solved by FlareSolverr.
  They'd route, via a new challenge kind, to a paid solver (CapSolver, 2captcha). The registry is
  the seam; it isn't built.
- **Fast-path-first costs one doomed request on a cold start.** nissei always challenges, so a
  per-site `always_challenges?` flag could skip it. With refresh-ahead keeping busy sites warm,
  cold starts are rare enough that I left it out.

## Honest limitations

- A browser is still required to solve. There's no free, reliable, browser-less way past an active
  JS challenge.
- Clearances are bound to UA + IP + TLS + headers. Everything here runs from one local IP with a
  matching profile; the FlareSolverr and curl-impersonate versions must be kept close.
- Requests waiting behind an in-flight solve have no deadline of their own. The solver's timeout
  (60s plus a 10s read grace) bounds them.
- A blocking cold request holds a Puma thread for the whole solve (~14s). Size the pool, or use
  the stream.

## Ethics and the target site

nissei is a real commercial site, and getting past its Cloudflare challenge touches its terms of
service. This is a private, read-only, **low-volume** practice project in the same dual-use space
that scraping APIs operate in commercially. Live traffic is kept to a trickle: tests run offline
against saved pages, and a live solve is a single, opt-in spec.

*On naming the site:* this README names nissei openly because the repo is private and the code
itself is nissei-specific (`NisseiController`, `NisseiParser`, fixtures). A public release should
revisit that and anonymize both the prose and the site-specific code.

---

## Running it

**Requirements:** Ruby 3.4, [curl-impersonate](https://github.com/lexiforest/curl-impersonate)
(lexiforest build) and Docker for [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr).
There's no database, Redis or job queue.

```bash
bundle install
docker run -d --name flaresolverr -p 8191:8191 ghcr.io/flaresolverr/flaresolverr:latest
bin/rails server

curl 'localhost:3000/api/v1/nissei/search?q=ps5'                 # one JSON body
curl -N 'localhost:3000/api/v1/nissei/search?q=ps5&stream=true'  # live events
```

| Env var | Default | What |
|---|---|---|
| `CURL_IMPERSONATE_DIR` | `~/curl-impersonate` | where the `curl-impersonate` binary lives |
| `FLARESOLVERR_URL` | `http://localhost:8191` | the FlareSolverr service |

**Tests** run fully offline (the fast path is injected, and FlareSolverr is stubbed with WebMock):

```bash
bundle exec rspec                     # the suite CI runs
LIVE=1 bundle exec rspec spec/live    # real curl-impersonate + one real solve against nissei
bin/rubocop && bin/brakeman
```

The live solver spec also refreshes `spec/fixtures/nissei_results.html`, the real captured page the
parser is tested against.
