module Scraper
  # Checks a scrape's output, not its page: given the JSON-ready data a parser
  # produced and a Contract of rules over JSON paths, Check reports how many
  # items carry each field (coverage) and which rules failed (issues). It
  # never sees HTML, selectors or parsers, so a new site gets it by declaring
  # a Contract.
  #
  # The one principle behind every rule: something that should always be
  # there is missing everywhere. A required field missing on every item, or a
  # structure that is always present coming back empty, is almost certainly a
  # broken selector (a layout the parser no longer understands), not missing
  # data, so it is reported instead of returned as a silent success.
  module Coverage
    module_function

    # nil, "", [] and {} hold no value, and neither does an object whose every
    # value is missing (filters with no categories, brands or colors). false
    # and 0 are values.
    def missing?(value)
      case value
      when nil then true
      when String, Array then value.empty?
      when Hash then value.values.all? { |v| missing?(v) }
      else false
      end
    end

    # [found, value] for `key` in a symbol- or string-keyed hash.
    def lookup(hash, key)
      return [true, hash[key]] if hash.key?(key)
      return [true, hash[key.to_sym]] if hash.key?(key.to_sym)

      [false, nil]
    end
  end
end
