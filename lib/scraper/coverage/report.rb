module Scraper
  module Coverage
    # What Check returns, JSON-ready (string keys): `coverage` maps every path
    # in the data to its counts; `issues` lists the Contract's failed rules,
    # empty when none failed.
    Report = Data.define(:coverage, :issues)
  end
end
