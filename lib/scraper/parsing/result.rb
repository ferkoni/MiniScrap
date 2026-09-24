module Scraper
  # One product card extracted by a Parser. `position` is its 1-based rank in
  # the result list, in document order.
  Result = Data.define(:title, :price, :availability, :url, :position)
end
