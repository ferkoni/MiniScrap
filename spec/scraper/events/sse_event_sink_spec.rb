require "rails_helper"

# The streaming sink writes standard Server-Sent Events frames to any writable
# stream — plain Ruby, so it is tested against a StringIO.
RSpec.describe Scraper::SseEventSink do
  let(:stream) { StringIO.new }
  let(:now) { [10.0] }
  subject!(:sink) { described_class.new(stream, clock: -> { now.first }) }

  it "writes one event: / data: frame per event, data as JSON" do
    sink.emit(:fast_path, attempt: 1, clearance: false)

    expect(stream.string).to eq(%(event: fast_path\ndata: {"attempt":1,"clearance":false,"elapsed_ms":0}\n\n))
  end

  it "stamps each frame with the milliseconds elapsed since the stream began" do
    now[0] = 10.25
    sink.emit(:fast_path, attempt: 1)
    now[0] = 13.5004
    sink.emit(:solving, kind: :cloudflare_js)

    expect(stream.string.scan(/"elapsed_ms":(\d+)/).flatten).to eq(%w[250 3500])
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
