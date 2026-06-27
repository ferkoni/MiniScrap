require "rails_helper"

# Smoke test proving the RSpec wiring is functional. Safe to delete once real specs exist.
RSpec.describe "RSpec setup" do
  it "loads the Rails environment" do
    expect(Rails.env).to eq("test")
  end
end
