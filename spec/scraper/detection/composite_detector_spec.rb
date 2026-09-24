require "rails_helper"

# CompositeDetector runs an ordered list and returns the first hit, so detectors
# compose without the flow knowing how many there are.
RSpec.describe Scraper::CompositeDetector do
  let(:response) { Scraper::Response.new(status: 200, headers: {}, body: "") }

  # A tiny stand-in so the composite is tested in isolation from any real
  # detector's marker logic.
  def detector(returns:)
    instance_double(Scraper::CloudflareDetector, detect: returns)
  end

  it "returns the first matching detector's Challenge" do
    first = Scraper::Challenge.new(kind: :cloudflare_js, evidence: { status: 403 })
    second = Scraper::Challenge.new(kind: :datadome, evidence: {})

    composite = described_class.new([detector(returns: nil), detector(returns: first), detector(returns: second)])

    expect(composite.detect(response)).to eq(first)
  end

  it "returns nil when no detector matches" do
    composite = described_class.new([detector(returns: nil), detector(returns: nil)])

    expect(composite.detect(response)).to be_nil
  end

  it "returns nil for an empty detector list" do
    expect(described_class.new([]).detect(response)).to be_nil
  end
end
