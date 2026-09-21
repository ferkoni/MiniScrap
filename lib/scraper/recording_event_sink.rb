module Scraper
  # Records every event in order, so specs can assert the narrated sequence
  # offline.
  class RecordingEventSink
    include EventSink

    attr_reader :events

    def initialize
      @events = []
    end

    def emit(event, data = {})
      @events << [event, data]
    end

    def names
      @events.map(&:first)
    end
  end
end
