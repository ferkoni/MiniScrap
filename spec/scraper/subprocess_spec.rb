require "rails_helper"

# The runner the curl fetcher shells out through. Exercised with tiny real
# processes (ruby, sleep) so the kill-on-timeout path is proven for real.
RSpec.describe Scraper::Subprocess do
  it "captures stdout, stderr, and the exit status" do
    result = described_class.run(["ruby", "-e", "print 'out'; warn 'err'; exit 3"], timeout: 5)

    expect(result.stdout).to eq("out")
    expect(result.stderr).to eq("err\n")
    expect(result.exitstatus).to eq(3)
    expect(result.success?).to be(false)
  end

  it "reports success for a zero exit" do
    expect(described_class.run(["ruby", "-e", "exit 0"], timeout: 5).success?).to be(true)
  end

  it "kills a process that outlives its timeout and raises TimedOut instead of hanging" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect { described_class.run(["sleep", "5"], timeout: 0.2) }.to raise_error(Scraper::Subprocess::TimedOut)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
  end
end
