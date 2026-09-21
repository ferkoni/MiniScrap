require "rails_helper"

# The streaming sink writes standard Server-Sent Events frames to any writable
# stream — plain Ruby, so it is tested against a StringIO.
RSpec.describe Scraper::SseEventSink do
  let(:stream) { StringIO.new }
  subject(:sink) { described_class.new(stream) }

  it "writes one event: / data: frame per event, data as JSON" do
    sink.emit(:fast_path, attempt: 1, clearance: false)

    expect(stream.string).to eq(%(event: fast_path\ndata: {"attempt":1,"clearance":false}\n\n))
  end

  it "writes events in the order they are emitted" do
    sink.emit(:fast_path, attempt: 1)
    sink.emit(:solving, kind: :cloudflare_js)

    expect(stream.string.scan(/^event: (\w+)$/).flatten).to eq(%w[fast_path solving])
  end

  it "keeps every frame on a single data line, even for multi-line text" do
    sink.emit(:done, note: "line one\nline two")

    expect(stream.string.lines.grep(/^data: /).size).to eq(1)
  end
end
