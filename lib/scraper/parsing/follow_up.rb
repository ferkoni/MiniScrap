module Scraper
  # A background request the page's own scripts would make, for content the
  # server HTML lacks (e.g. nissei's home carousels). A Parser declares its
  # follow-ups; ScrapeFlow fetches them after the page, with the page's
  # clearance, and hands their bodies back to Parser#parse_page keyed by
  # `name`. `path` is site-relative, like the page's; `headers` are sent on
  # top of the clearance's.
  FollowUp = Data.define(:name, :path, :headers)
end
