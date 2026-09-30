require "json"

module Scraper
  # Writes each event as a Server-Sent Events frame to a writable stream (the
  # controller passes the live response stream):
  #
  #   event: solving
  #   data: {"kind":"cloudflare_js","elapsed_ms":412}
  #
  # Every frame carries `elapsed_ms` since the sink was built (the start of the
  # stream), so the gap between two frames is how long that step took.
  #
  # Data is JSON on a single line — JSON escapes newlines, so a frame can never
  # be split by its payload.
  class SseEventSink
    include EventSink

    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    def initialize(stream, clock: MONOTONIC)
      @stream = stream
      @clock = clock
      @started_at = clock.call
    end

    def emit(event, data = {})
      payload = data.merge(elapsed_ms: ((@clock.call - @started_at) * 1000).round)
      @stream.write("event: #{event}\ndata: #{payload.to_json}\n\n")
    end
  end
end
