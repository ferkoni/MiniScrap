require "rails_helper"

# The acceptance test for the coverage check (finding 3 of the July review:
# "every failure is silent"). Each example renames selectors in a real
# captured page, the way a site redesign would, and asserts on the API body:
# either a fallback still gives the same output, or the break is flagged in
# `degraded`. Optional fields can legitimately vanish from a whole page, so
# for those the drop shows in `coverage` only — pinned here so a change to
# that is deliberate.
RSpec.describe "Renamed selectors in real pages", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:store) { Scraper::ClearanceStore.new(registry: Scraper::SolverRegistry.new) }

  before do
    travel_to Time.utc(2026, 9, 25, 12)
    allow(Api::V1::ScrapeController).to receive(:clearance_store).and_return(store)
  end

  after { travel_back }

  def fixture(path)
    Rails.root.join("spec/fixtures", path).read
  end

  # The API body for `html` served as a clean 200 at `endpoint`.
  def scrape(endpoint, html, params = {})
    fetcher = Scraper::FakeFetcher.new(responses: [Scraper::Response.new(status: 200, headers: {}, body: html)])
    allow(Scraper::CurlImpersonateFetcher).to receive(:new).and_return(fetcher)
    get endpoint, params: params
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  # Renames every class token starting with `prefix` (e.g. "price",
  # "price-box", "old-price"), so no class selector on it can match.
  def rename_classes(html, prefix)
    html.gsub(/class="([^"]*)"/) { %(class="#{::Regexp.last_match(1).gsub(/\b#{prefix}/, "zz#{prefix}")}") }
  end

  def missing_field(path, of)
    { "code" => "missing_field", "path" => path, "present" => 0, "of" => of }
  end

  describe "Booking search" do
    let(:page) { fixture("booking/search.html") }
    let(:params) { { dest_id: "-910015", dest_type: "city", checkin: "2026-09-30", checkout: "2026-10-08" } }
    let(:original) { scrape("/api/v1/booking/search", page, params) }

    def booking(html) = scrape("/api/v1/booking/search", html, params)

    it "flags nothing on the page as captured" do
      expect(original["results"].length).to eq(15)
      expect(original["degraded"]).to be_nil
    end

    it "gives the same output when the card's test id is renamed (fallback)" do
      body = booking(page.gsub('data-testid="property-card"', 'data-testid="zz-card"'))

      expect(body["results"]).to eq(original["results"])
      expect(body["degraded"]).to be_nil
    end

    it "flags price when its only selector is renamed" do
      body = booking(page.gsub("price-and-discounted-price", "zz-price"))

      expect(body["degraded"]).to eq([missing_field("results[].price", 15)])
    end

    it "flags address when both address selectors are renamed" do
      body = booking(page.gsub('data-testid="address', 'data-testid="zz-address'))

      expect(body["degraded"]).to eq([missing_field("results[].address", 15)])
    end

    it "flags image_url when every image selector is renamed" do
      body = booking(page.gsub("<img", "<zzimg"))

      expect(body["degraded"]).to eq([missing_field("results[].image_url", 15)])
    end

    it "flags an empty page when every title link selector is renamed" do
      body = booking(page.gsub('data-testid="title-link"', 'data-testid="zz-link"').gsub(/<(\/?)h3\b/, '<\1zzh3'))

      expect(body["results"]).to eq([])
      expect(body["degraded"]).to eq([{ "code" => "empty", "path" => "results" }])
    end

    it "shows optional review scores dropping in coverage only" do
      body = booking(page.gsub('data-testid="review-score"', 'data-testid="zz-review"'))

      expect(body["coverage"]["results[].review_score"]).to eq("present" => 0, "of" => 15)
      expect(body["degraded"]).to be_nil
    end

    it "shows optional official stars dropping in coverage only" do
      body = booking(page.gsub('data-testid="rating-stars"', 'data-testid="zz-stars"'))

      expect(original["coverage"]["results[].stars"]).to eq("present" => 12, "of" => 15)
      expect(body["coverage"]["results[].stars"]).to eq("present" => 5, "of" => 15)
      expect(body["degraded"]).to be_nil
    end
  end

  describe "nissei search" do
    let(:page) { fixture("nissei/results_smartphone.html") }
    let(:original) { scrape("/api/v1/nissei/search", page, q: "smartphone") }

    def nissei(html) = scrape("/api/v1/nissei/search", html, q: "smartphone")

    it "flags nothing on the page as captured" do
      expect(original["results"].length).to eq(45)
      expect(original["degraded"]).to be_nil
    end

    it "gives the same output when the title link class is renamed (fallback)" do
      body = nissei(rename_classes(page, "product-item-link"))

      expect(body["results"]).to eq(original["results"])
      expect(body["degraded"]).to be_nil
    end

    it "flags price when every price selector is renamed" do
      body = nissei(rename_classes(page, "price").gsub("data-price-type", "data-zz-type"))

      expect(body["degraded"]).to eq([missing_field("results[].price", 45)])
    end

    it "flags the filters when every filter group's hooks are renamed" do
      body = nissei(page.gsub("data-amshopby-filter", "data-zz-filter").gsub("am-filter-items", "zz-filter-items"))

      expect(body["results"].length).to eq(45)
      expect(body["filters"]).to eq("categories" => [], "brands" => [], "colors" => [])
      expect(body["degraded"]).to eq([{ "code" => "empty", "path" => "filters" }])
    end

    it "shows optional discounts dropping in coverage only" do
      body = nissei(rename_classes(page, "discount-percent"))

      expect(original["coverage"]["results[].discount"]).to eq("present" => 9, "of" => 45)
      expect(body["coverage"]["results[].discount"]).to eq("present" => 0, "of" => 45)
      expect(body["degraded"]).to be_nil
    end

    it "shows optional promo labels dropping in coverage only, as nil rather than false" do
      body = nissei(rename_classes(rename_classes(page, "amlabel-text"), "amasty-label-container"))

      expect(original["coverage"]["results[].free_delivery"]).to eq("present" => 39, "of" => 45)
      expect(body["coverage"]["results[].free_delivery"]).to eq("present" => 0, "of" => 45)
      expect(body["results"].map { |result| result["free_delivery"] }.uniq).to eq([nil])
      expect(body["degraded"]).to be_nil
    end
  end

  describe "nissei home" do
    let(:page) { fixture("nissei/home.html") }
    let(:original) { scrape("/api/v1/nissei/home", page) }

    def home(html) = scrape("/api/v1/nissei/home", html)

    it "flags nothing on the page as captured" do
      expect(original["results"].length).to eq(13)
      expect(original["degraded"]).to be_nil
    end

    it "flags every section left without products when the card selectors are renamed" do
      body = home(rename_classes(page, "product-item"))

      expect(body["results"].length).to eq(13)
      expect(body["degraded"]).to eq((0...13).map { |index| { "code" => "empty", "path" => "results[#{index}].products" } })
    end

    # A documented limit (Coverage REQUIREMENTS §4): sections that vanish
    # outright leave a well-formed list, and the carousels are legitimately
    # absent for some visitors. The home restructure addresses it.
    it "does not flag the category showcases disappearing" do
      body = home(rename_classes(page, "block-main-product"))

      expect(body["results"].map { |section| section["name"] }).to eq(%w[recommended may_like continue_buying gift_ideas best_sellers])
      expect(body["degraded"]).to be_nil
    end
  end
end
