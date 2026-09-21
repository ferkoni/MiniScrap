require "rails_helper"

# The registry routes a Challenge to the Solver registered for its kind, so a
# new protection is one entry here — and an unrouted kind fails honestly.
RSpec.describe Scraper::SolverRegistry do
  let(:solver) { Scraper::StubSolver.new }
  let(:registry) { described_class.new(cloudflare_js: solver) }

  def challenge(kind)
    Scraper::Challenge.new(kind: kind, evidence: { status: 403 })
  end

  it "returns the solver registered for the challenge's kind" do
    expect(registry.for(challenge(:cloudflare_js))).to be(solver)
  end

  it "raises UnsupportedChallenge carrying the kind when none is registered" do
    expect { registry.for(challenge(:datadome)) }.to raise_error(Scraper::UnsupportedChallenge) do |error|
      expect(error.kind).to eq(:datadome)
    end
  end
end
