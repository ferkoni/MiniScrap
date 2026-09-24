require "rails_helper"

# Where egress proxies come from: round-robin over a configured list, or no
# proxy at all. Each proxy gets its own clearance (the key includes it).
RSpec.describe Scraper::ProxyPool do
  it "rotates through its proxies" do
    pool = described_class.new(["http://a:1", "http://b:2"])
    expect(Array.new(5) { pool.next }).to eq(["http://a:1", "http://b:2", "http://a:1", "http://b:2", "http://a:1"])
  end

  it "hands out no proxy when none is configured" do
    expect(described_class.new([]).next).to be_nil
  end

  it "reads a comma-separated list, ignoring blanks" do
    expect(described_class.parse(" http://a:1 , ,http://b:2 ").proxies).to eq(["http://a:1", "http://b:2"])
    expect(described_class.parse(nil).proxies).to eq([])
  end

  it "shares the rotation fairly across threads" do
    pool = described_class.new(["http://a:1", "http://b:2"])
    picks = Array.new(4) { Thread.new { Array.new(50) { pool.next } } }.flat_map(&:value)
    expect(picks.tally).to eq("http://a:1" => 100, "http://b:2" => 100)
  end
end
