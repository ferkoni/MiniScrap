module Scraper
  # Discards every event: the default sink, so a non-streaming request pays
  # nothing for the narration seam.
  class NullEventSink
    include EventSink

    def emit(_event, _data = {}); end
  end
end
