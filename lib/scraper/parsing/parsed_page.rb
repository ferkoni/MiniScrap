module Scraper
  # What Parser#parse_page returns: the page's records, plus the search
  # filters it offers when the page has any (nil for a page that has none).
  ParsedPage = Data.define(:results, :filters) do
    # The JSON-ready part of the response the parser owns: what the API
    # renders and what the coverage check reads, so the checked data is the
    # rendered data. `results` is a list of records, or one record for a page
    # that isn't a list (nissei home). `filters` appears only when present.
    def data
      rendered = results.is_a?(Array) ? results.map(&:to_h) : results.to_h
      { results: rendered, filters: filters&.to_h }.compact
    end
  end
end
