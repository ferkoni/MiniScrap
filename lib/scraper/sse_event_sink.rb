require "json"

module Scraper
  # Writes each event as a Server-Sent Events frame to a writable stream (the
  # controller passes the live response stream):
  #
  #   event: solving
  #   data: {"kind":"cloudflare_js"}
  #
  # Data is JSON on a single line — JSON escapes newlines, so a frame can never
  # be split by its payload.
  class SseEventSink
    include EventSink

    def initialize(stream)
      @stream = stream
    end

    def emit(event, data = {})
      @stream.write("event: #{event}\ndata: #{data.to_json}\n\n")
    end
  end
end
