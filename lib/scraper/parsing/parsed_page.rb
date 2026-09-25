module Scraper
  # What Parser#parse_page returns: the page's records, plus the search
  # filters it offers when the page has any (nil for a page that has none).
  ParsedPage = Data.define(:results, :filters)
end
