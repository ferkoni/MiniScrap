# MiniScrap: solve Cloudflare once, scrape cheaply after

MiniScrap is a small Rails API that returns clean JSON search results from
[nissei.com](https://nissei.com/py/), a real Paraguayan e-commerce site behind **Cloudflare's
managed challenge**. The interesting part isn't the scraping. It's getting in: how to beat a
challenge that needs a real browser **without** putting a browser on every request.

A second site, [Booking.com](https://www.booking.com/) hotel search behind **AWS WAF's JavaScript
challenge**, runs on the same design, unchanged (see *Booking* below).

```
GET /api/v1/nissei/search?q=ps5
```
```jsonc
{ "site": "nissei",
  "results": [ { "title": "Juego PS5 Saros", "price": "Gs. 520.000",
                 "old_price": null, "discount": null,
                 "online_only": null, "free_delivery": null,
                 "url": "https://nissei.com/py/juego-ps5-saros",
                 "image_url": "https://nissei.com/media/catalog/product/…",
                 "position": 1 }, … ],
  "filters": { "categories": […], "brands": […], "colors": […] },
  "browser_used": true, "latency_ms": 13893,
  "coverage": { "results[].price": { "present": 45, "of": 45 }, … }, "degraded": null }
```

Search also returns `filters`: the sidebar's category tree, brands and colors, each option with
nissei's filter id (`value`) and the `url` that applies it.

`GET /api/v1/nissei/home` returns the same envelope (without `filters`), but `results` is the home
page's parts, each addressed by a stable key rather than found by searching a list:

```jsonc
{ "site": "nissei",
  "results": {
    "carousels": {
      "recommended":     { "title": "Precios especiales en tus categorías top", "fallback": false, "products": [ … ] },
      "may_like":        { "title": "Tus próximas compras favoritas", "fallback": false, "products": [ … ] },
      "continue_buying": { … },
      "gift_ideas":      null,                         // not returned this time
      "best_sellers":    { … } },
    "categories": [
      { "title": "Fotografía y Filmación", "url": "https://nissei.com/py/fotografia-filmacion", "products": [ … ] },
      … ] },
  "browser_used": false, "latency_ms": …,             // both requests
  "coverage": { … }, "degraded": null }
```

- **`carousels` always has all five keys.** One nissei didn't return is `null`, so the shape is
  the same on every request. `fallback` is nissei's own `is_fallback` flag, passed through.
- **`categories`** are the page's showcases, in page order. `url` is the category page the
  showcase's heading links to: a category's one identifier that isn't page text.
- **Products** have the same shape as search's: both pages render the same card, read by one
  shared `Nissei::CardExtractor`.

**`/home` makes two requests to nissei.** The carousels aren't in the page's HTML: its script
loads them from nissei's own `aipersonalization/ajax/sections` endpoint. So after the page,
`HomeParser` declares that request as a *follow-up*, and the flow makes it over the same fast
path, with the same clearance, UA and proxy (no browser). `latency_ms` covers both. If the
follow-up fails (a network error, a non-2xx, or a challenge, which isn't solved for an optional
part), `/home` still returns `200` with the categories, every carousel `null`, and why in
`degraded`: `{ "code": "follow_up_failed", "name": "carousels", "reason": "status 500" }`, next to
one `empty` issue per missing carousel. Home shares search's clearance, so it never pays its own
solve.

Measured against the live site: the **first** request pays one browser solve (~14s, `browser_used:
true`). **Every request after that** reuses the result over plain HTTP (~3s, `browser_used: false`).

### Booking

```
GET /api/v1/booking/search?dest_id=-910015&dest_type=city&checkin=2026-09-30&checkout=2026-10-08&adults=2
GET /api/v1/booking/search?ss=Asuncion&checkin=2026-09-30&checkout=2026-10-08&offset=15
```
```jsonc
{ "site": "booking",
  "results": [ { "name": "Danieri Asunción Hotel",
                 "url": "https://www.booking.com/hotel/py/di-danieri.es.html",
                 "address": "Asunción", "distance": "a 6,9 km del centro",
                 "review_score": "8,3", "review_label": "Muy bien", "review_count": "1.056 comentarios",
                 "stars": 3, "stars_kind": "official",
                 "price": "US$714", "taxes_note": "+ US$71 de impuestos y cargos",
                 "stay": "8 noches, 2 adultos", "image_url": "https://cf.bstatic.com/…",
                 "position": 5 }, … ],
  "browser_used": false, "latency_ms": 1250,
  "coverage": { "results[].price": { "present": 15, "of": 15 }, … }, "degraded": null }
```

- **Typed params, not a pasted URL.** The destination is `dest_id` + `dest_type`, or free-text
  `ss` (`dest_id` wins when both are given). Then `checkin`, `checkout`, `adults`, `rooms`,
  `children` and `offset`. Invalid input is a `400` listing every bad param, before any fetch.
  The URL sent to Booking is rebuilt from these alone, with the currency pinned to USD. None of
  Booking's tracking or session params (`sid`, `aid`, `label`, …) are ever forwarded.
- **Positions are absolute across pages:** with `offset=15`, the first result is position 16.
- **The challenge is AWS WAF's**, not Cloudflare's: a `202` whose script earns an `aws-waf-token`
  cookie and reloads. `AwsWafDetector` recognises it; FlareSolverr solves it once, and the fast
  path replays the token. Measured live: a cold solve takes ~12s, a warm request ~1.3s.

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
`latency_ms` is a cold start, and `false` with a low one is a cache hit. `coverage` and `degraded`
report whether the parse itself can be trusted (§7).

To watch it as it happens, ask for a stream (`Accept: text/event-stream` or `?stream=true`):

```
event: fast_path  {"attempt":1,"clearance":false,"elapsed_ms":210}
event: solving    {"kind":"cloudflare_js","elapsed_ms":215}
event: fast_path  {"attempt":2,"clearance":true,"elapsed_ms":14890}
event: done       { …the same body as the JSON endpoint…, "elapsed_ms":15300 }
```

Every event carries `elapsed_ms` since the stream began, so the gap between two events is how long
that step took (above: the solve took ~14.7s).

`/home` adds a `follow_up {"name":"carousels"}` event before `done`, for its second request.

The streaming variant was added **without touching the core**. `ScrapeFlow` narrates to an injected
`EventSink` and still *returns* its result; only the edge decides whether that becomes one JSON body
or a stream.

## 6. The shape: two sites today, more tomorrow

The scraping core is plain Ruby under `lib/scraper/`, and Rails only appears in the controllers.
The orchestrator names only interfaces and contains no `if site == …` or `if cloudflare`:

| Layer | Pieces |
|---|---|
| Edge (Rails) | `ScrapeController` (wiring, JSON/SSE rendering, error → status, `400 invalid_params`) · `NisseiController`, `BookingController` (declare the site) |
| Orchestrator | `ScrapeFlow`: fast fetch → detect → single-flight solve → bounded retry → parse |
| Strategies | `Fetcher` (`CurlImpersonateFetcher`) · `ChallengeDetector` (`CloudflareDetector`, `AwsWafDetector`, `CompositeDetector`) · `Solver` + `SolverRegistry` (`FlareSolverrSolver`) · `Parser` (`Nissei::SearchParser`, `Nissei::HomeParser`, sharing `Nissei::CardExtractor`; `Booking::SearchParser`) · `EventSink` |
| Shared state | `ClearanceStore`: the one long-lived mutable object |

| To add… | You write… | Untouched |
|---|---|---|
| a site | a ~5-line controller subclass (`scrapes "…", base_url:, profile:`: the identity its clearance is bound to) + a route | flow, store |
| a protection (e.g. DataDome) | a detector returning `Challenge(:datadome)` + one registry entry | flow, controllers |
| an endpoint | a one-line action: `scrape(path, parser:, contract:)` + a route. It shares the site's clearance | everything else |

**Booking tested this table.** Adding it took a controller, a route, a parser, a detector and a
registry entry, as the table says, with `ScrapeFlow` and `ClearanceStore` untouched. It also
exposed two Cloudflare assumptions in `FlareSolverrSolver`, which became per-instance settings:
the name of the cookie that proves a solve (`cf_clearance` vs `aws-waf-token`), and a `wait`.
FlareSolverr only recognises Cloudflare's challenge; on AWS WAF's it returns at once, before the
challenge script has earned its token, so the browser is kept running 10s longer.

An unrecognised protection raises `UnsupportedChallenge`, which is a `501`, rather than failing
silently. Other failures map to honest statuses: `502` for `solve_failed`, `retry_budget_exhausted`
or `fetch_failed`, and `504` for `solve_timeout`.

The parser uses **layered selectors** (a primary selector with fallbacks for every field) and emits
a source-agnostic shape. nissei's promo labels ("Solo Online", "Delivery Gratis") become
`online_only` and `free_delivery` rather than nissei's wording: `true` when the card shows the
label and `null` otherwise, never `false`, since the page never says a card lacks one. A
hand-made "layout-shifted" fixture renames every primary hook to prove the fallbacks work.
Checking the parser against the real page also caught a phantom result: a wishlist-sidebar
template shared the product-card class.

## 7. Knowing when the parser broke

Fallbacks keep the fields that identify a result alive through a redesign. Everything else used
to fail silently. Renaming Booking's price hook left all 15 prices `null`; renaming nissei's
filter hooks emptied the whole filter sidebar; renaming its card classes left all 13 home
sections with no products. Each came back as an ordinary `200` with `degraded: null`: the API
would have shipped broken data and nobody would have known until a client complained.

Now every response is checked, and the check never looks at the page. It reads the JSON the API
is about to return, against a small contract each endpoint declares as JSON paths:

```ruby
SEARCH_CONTRACT = Scraper::Coverage::Contract.new(
  non_empty: %w[results],
  required: %w[name url price address image_url].map { |field| "results[].#{field}" }
)
```

- **`non_empty`:** the array or object has content. Under `[]` it applies to each element, so one
  empty home category is named by its index (`results.categories[3].products`). nissei's
  `filters` counts as empty only when categories, brands and colors are all empty, since one
  empty group can be real.
- **`required`:** the field has a value on at least one result. Missing on every result means a
  selector broke; missing on some is data. A real home page showed one product with no price, 172
  of 173, and that must not be flagged.

A broken selector then reads:

```jsonc
"coverage": { "results[].price": { "present": 0, "of": 15 }, … },
"degraded": [ { "code": "missing_field", "path": "results[].price", "present": 0, "of": 15 } ]
```

`coverage` comes with every response, counting every field, so a drop in an optional field is at
least visible. An empty page is just `non_empty: results` failing, the default for a site that
declares nothing more. The status stays `200`: partial data, marked as partial.

**What it can't see.** A field that can legitimately vanish from a whole page (reviews, stars,
discounts, promo labels) can't be checked from one page: 0 discounts looks exactly like a page
with no sales. Catching those needs rates across many searches, not one. (Home carousels used
to be in this list, when they came back as a flat list of sections. Now each has a fixed key, so
a missing one is flagged as `empty results.carousels.<name>.products`, and so is the page
losing its category showcases.)

Specs rename selectors in the real captured pages, the way a redesign would, and assert on the
API body. For a required field, the rename either hits a fallback and gives the same output, or
it's flagged. For an optional one, the spec pins the drop in `coverage`. Values also can't guess, or "missing" would mean nothing: a blank element is `null`, never `""`,
and a label the card doesn't show is `null`, not `false`.

## 8. What I deliberately scoped out, and how I'd build it at scale

- **Multi-host deployment.** The Kamal setup (see *Deploying*) is **one host**, because
  FlareSolverr must share the app's egress IP. It runs one process by default, or several workers
  with the shared store below. Going to several hosts also needs a shared egress (the proxy pool
  below), and isn't wired up in the Kamal config.
- **Shared store: built, opt-in.** Set `REDIS_URL` and the clearance cache and its single-flight
  lock move to Redis. Puma may then run workers (`WEB_CONCURRENCY`), and a cold herd spread across
  processes still costs **one** browser solve (measured: 6 concurrent requests over 2 workers,
  1 FlareSolverr solve). The per-key lock is `SET NX PX` with a token. The leader publishes its
  outcome (the clearance or its error) for waiters in any process, and a crashed leader's lock
  expires, so its waiters fail cleanly rather than hang. XFetch and compare-and-delete invalidation
  work the same across processes. Without `REDIS_URL`, the in-memory store is unchanged.
- **Proxy pool: built, opt-in.** `SCRAPER_PROXIES` (comma-separated) rotates requests over egress
  proxies. A clearance is keyed by `(site, profile, proxy)` and both solved and replayed through
  its proxy, so it's never presented from a different IP. Credentials never appear in Redis keys.
  Sharing Redis across *hosts* is only correct through such a pool or a common NAT, since a
  clearance is bound to its egress IP.
- **Browsers as a pool, not a container.** One FlareSolverr is enough at this volume. At scale:
  a pool of browser workers behind a queue, sized by solve rate rather than request rate.
- **Puzzle CAPTCHAs.** Cloudflare's one-click "Verify you are human" checkbox is not the limit:
  FlareSolverr presses it itself (Tab, then Space) when the challenge page doesn't clear on its
  own, and nissei's challenge does show it. A FlareSolverr debug log confirmed the click, and the
  solve passed. What's out of reach is a puzzle: reCAPTCHA or hCaptcha image grids, AWS WAF's
  CAPTCHA, sliders. Those would route, via a new challenge kind, to a paid solver (CapSolver,
  2captcha). The registry is the seam; it isn't built, and won't be (see *Ethics*).
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
- Booking's solve depends on a fixed 10s wait, and on FlareSolverr *not* recognising AWS WAF's
  challenge (it returns normally, and the wait lets the script finish). 10s worked; the minimum
  is unknown. Re-check it live when upgrading FlareSolverr.
- Booking's clearance is capped at 300s, AWS WAF's default immunity time. The token cookie claims
  4 days, and the real server-side lifetime wasn't measured, since measuring it takes sustained
  traffic. A cap that's too long costs one challenged fast fetch, then a fresh solve.
- A visible CAPTCHA (as opposed to the silent challenge) can't be solved and isn't attempted: the
  solve returns no token and the API answers `502 solve_failed`.
- nissei's checkbox is passed by a scripted key press (FlareSolverr tabs to it and presses Space).
  If Cloudflare moves the checkbox or starts rejecting keyboard-only clicks, cold solves fail
  until FlareSolverr catches up; warm requests keep working until the clearance expires.
- **`/home` has not been run through the fast path yet.** Its two fixtures are browser captures:
  the page saved from a browser, and the carousels' endpoint response captured in a private
  window. The live capture through curl-impersonate was blocked (Cloudflare refused the solve's IP
  that day), so it's still open whether the carousels' endpoint answers the fast path with the
  clearance cookies alone, or also wants the page's session cookie. If it doesn't, `/home` still
  returns `200` with the categories and flags the carousels in `degraded`.

## Ethics and the target site

nissei is a real commercial site, and getting past its Cloudflare challenge touches its terms of
service. MiniScrap is a read-only, **low-volume** learning project in the same dual-use space that
scraping APIs operate in commercially. It isn't a service and doesn't run against these sites on
a schedule. Live traffic is kept to a trickle: every test runs offline against saved pages, and a
live solve is a single, opt-in spec that CI never runs.

Booking's terms explicitly forbid automated access, a bigger step than nissei. Its fixtures come
from one live test of 4 page loads (a challenged fetch, two FlareSolverr solves, one warm fetch),
with no user cookies and no tracking params, and were scrubbed of session ids. There is no live
Booking spec; the same trickle rule applies.

What it deliberately doesn't do:
- **No CAPTCHA solving.** Only challenges a real browser passes on its own, or with a single
  click, are handled. Puzzles meant for people are out of scope, and so are paid solving services.
- **No personal data.** Only public catalogue and listing pages are read: no accounts, no logins,
  no user content.
- **Nothing sensitive in the repo.** Fixtures are scrubbed of cookies, session ids and tracking
  ids.

*On naming the sites:* the README names nissei and Booking because the code is site-specific
(`NisseiController`, `BookingController`, the `Scraper::Nissei` and `Scraper::Booking` parsers,
fixtures), and the concrete details are the point: a real challenge, measured against a real
site. If you run it, keep to the same trickle, and read each site's terms first.

---

## Running it in development

**You need:** Ruby 3.4.9, Docker, and curl-impersonate. There's no database, Redis or job queue.

### 1. Ruby and gems

`.ruby-version` pins Ruby 3.4.9, and `.ruby-gemset` names an RVM gemset (`miniscrap`), which RVM
picks up automatically on `cd`. rbenv, asdf and mise read `.ruby-version` too.

```bash
bin/setup --skip-server     # bundle install + clear logs/tmp
```

### 2. curl-impersonate (the fast path)

The fast path shells out to the `curl-impersonate` binary from the
[lexiforest build](https://github.com/lexiforest/curl-impersonate). MiniScrap was built and tested
against **v1.5.6**; its newest Chrome profile is `chrome146`, which the nissei site declares. Download
the tarball for your platform (`x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-macos`,
`arm64-macos`, …) and unpack it; the files sit at the top level of the archive:

```bash
mkdir -p ~/curl-impersonate && cd ~/curl-impersonate
curl -LO https://github.com/lexiforest/curl-impersonate/releases/download/v1.5.6/curl-impersonate-v1.5.6.x86_64-linux-gnu.tar.gz
tar xzf curl-impersonate-v1.5.6.x86_64-linux-gnu.tar.gz
./curl-impersonate --version    # curl 8.15.0-IMPERSONATE …
```

Anywhere other than `~/curl-impersonate` works too; point `CURL_IMPERSONATE_DIR` at it.

### 3. FlareSolverr (the slow path)

FlareSolverr is a long-running service that the app calls; the app never spawns it. Run it in
Docker. `v3.5.2` is the tested version (its Chromium is Chrome 152, the closest match for the
`chrome146` TLS profile):

```bash
docker run -d --name flaresolverr -p 8191:8191 ghcr.io/flaresolverr/flaresolverr:v3.5.2
curl -s localhost:8191/     # {"msg": "FlareSolverr is ready!", "version": "3.5.2", …}
```

Or, with the same image and port, from `docker-compose.yml` (which also runs from an IDE such as
RubyMine): `docker compose up -d`, and `docker compose down` to stop it. Keep its tag in step with
`config/deploy.yml`.

It only does work on a cold start or when a clearance dies. Stop it with
`docker rm -f flaresolverr`.

### 4. Start the app

```bash
bin/dev                     # = bin/rails server, on http://localhost:3000 (PORT to change)
```

```bash
curl 'localhost:3000/api/v1/nissei/search?q=ps5'                 # one JSON body
curl -N 'localhost:3000/api/v1/nissei/search?q=ps5&stream=true'  # live events (-N: don't buffer)
curl 'localhost:3000/api/v1/nissei/home'                         # home carousels + category showcases (2 requests to nissei)
curl 'localhost:3000/api/v1/booking/search?ss=Asuncion&checkin=2026-09-30&checkout=2026-10-08&adults=2'
curl 'localhost:3000/up'                                         # health check
```

The first search after boot is a cold start (`browser_used: true`, ~15s). Later ones reuse the
cached clearance (`browser_used: false`, a few seconds) until it expires or dies. The clearance
lives in the server process's memory, so **restarting the server means the next request is cold
again.**

| Env var | Default | What |
|---|---|---|
| `CURL_IMPERSONATE_DIR` | `~/curl-impersonate` | directory holding the `curl-impersonate` binary |
| `FLARESOLVERR_URL` | `http://localhost:8191` | the FlareSolverr service |
| `PORT` | `3000` | the Puma port |
| `REDIS_URL` | unset | share the clearance cache + single-flight lock across processes (allows `WEB_CONCURRENCY`) |
| `SCRAPER_PROXIES` | unset | comma-separated egress proxies, round-robin; each gets its own clearance |

`GET /ready` reports whether curl-impersonate and FlareSolverr are both usable (`200` or `503`,
naming each check).

Background refresh-ahead solves (XFetch) don't appear in any response. Look for
`[ClearanceStore] refresh-ahead …` lines in `log/development.log`.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `502 {"error":"fetch_failed"}` | curl-impersonate isn't at `CURL_IMPERSONATE_DIR`, or the site is unreachable |
| `502 {"error":"solve_failed"}` mentioning *Connection refused* | FlareSolverr isn't running, or isn't at `FLARESOLVERR_URL` |
| `504 {"error":"solve_timeout"}` | FlareSolverr couldn't clear the challenge within 60s |
| `502 {"error":"retry_budget_exhausted"}` | a fresh clearance was still challenged, usually because FlareSolverr's Chrome version and the curl-impersonate profile drifted too far apart (see §3) |
| `200` with `"degraded":[…]` | the page loaded but the parse broke a coverage rule (e.g. `results` empty, or a field missing on every result); the site's layout may have changed (see §7) |

### Tests and checks

Tests run fully offline: the fast path is injected, and FlareSolverr is stubbed with WebMock. You
don't need Docker or curl-impersonate for them.

```bash
bin/ci                                # everything below in one go, as GitHub Actions runs it
bundle exec rspec                     # the suite CI runs (Redis specs need REDIS_URL, below)
bin/rubocop                           # style
bin/brakeman --no-pager               # security scan
bin/bundler-audit                     # gem advisories
```

The `:redis` specs (the Redis backend, including its cross-process guarantees) run when `REDIS_URL`
is set, as it is in CI. Locally, use a throwaway Redis, not one you care about:

```bash
docker run -d --name miniscrap-redis -p 127.0.0.1:6380:6379 redis:7-alpine
REDIS_URL=redis://127.0.0.1:6380/15 bundle exec rspec
```

The `:live` specs hit the real network, so they're opt-in and never run in CI. They need steps 2 and 3:

```bash
LIVE=1 bundle exec rspec spec/live    # a real curl-impersonate fetch + one real solve against nissei
```

The live solver spec also refreshes `spec/fixtures/nissei/results.html`, one of the two real
captured search pages the parser is tested against (the other is `results_smartphone.html`, whose cards carry the promo labels). Keep live runs rare (see *Ethics* above).

## Deploying

The production image and a [Kamal](https://kamal-deploy.org) config are included. Everything runs on
**one host**: the app and FlareSolverr must share an egress IP, because a clearance is bound to the
IP that solved it.

**What the image and config do:**
- **The image** bakes in curl-impersonate **v1.5.6**, pinned by version and SHA-256 and verified at
  build time, at `/opt/curl-impersonate`.
- **Thruster** gets a 90s write timeout, so a cold solve can run to its deadline. Its gzip is off,
  because gzip buffers the SSE stream into one lump.
- **FlareSolverr `v3.5.2`** runs as a Kamal accessory (`miniscrap-flaresolverr`). It's never
  published; the app reaches it over Kamal's Docker network.
- **kamal-proxy** gets a 90s response timeout and unbuffered responses, for the same two reasons.
  It health-checks `/up`.
- **One Puma process, 16 threads, by default.** `config/puma.rb` refuses `WEB_CONCURRENCY > 1`
  unless `REDIS_URL` is set, because otherwise the clearance cache is per-process memory. The
  commented `redis` accessory and env lines in `config/deploy.yml` switch on workers.

**First deploy:**

```bash
export MINISCRAP_SERVER=203.0.113.10          # your host (SSH as root by default)
export KAMAL_REGISTRY_USERNAME=your-user      # ghcr.io user
export KAMAL_REGISTRY_PASSWORD=ghp_…          # registry token
bin/kamal setup                               # installs Docker, boots FlareSolverr + the app
bin/smoke http://$MINISCRAP_SERVER            # ready → cold search → warm search → live stream
```

Later deploys are `bin/kamal deploy`. `bin/kamal ready` asks a running container whether
curl-impersonate and FlareSolverr are both usable (`/ready`). `/up` stays liveness-only, so a
browser outage shows up there and in monitoring rather than blocking a deploy.

For HTTPS, set `proxy.host` and `ssl: true` in `config/deploy.yml`, then enable
`config.assume_ssl` / `config.force_ssl`.

**Upgrading either pin is one deliberate change.** Move the FlareSolverr image and the
curl-impersonate version, profile and checksum together, since they have to stay close. Then rerun
`LIVE=1 bundle exec rspec spec/live` and `bin/smoke`.

`bin/smoke` was run against a local rehearsal of this setup: the built image plus FlareSolverr on a
private Docker network, fronted by Thruster. It showed a cold solve (~13s), a warm hit (~1.5–3s), and
an unbuffered stream. It also caught the gzip buffering described above.

