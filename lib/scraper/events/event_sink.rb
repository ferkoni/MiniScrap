module Scraper
  # Interface for narrating a scrape as it happens:
  #
  #   emit(event, data = {})
  #
  # ScrapeFlow emits `fast_path` before each fetch and `solving` before a
  # solve, and still *returns* its ScrapeResult — so the output medium stays
  # at the edge. Impls: NullEventSink (the plain JSON path), SseEventSink
  # (Server-Sent Events), RecordingEventSink (specs).
  module EventSink
    def emit(_event, _data = {})
      raise NotImplementedError, "#{self.class} must implement #emit"
    end
  end
end
