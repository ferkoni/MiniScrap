module Scraper
  # Interface for turning a cleared HTML body into a list of records, or one
  # record for a page that isn't a list, each responding to #to_h (ScrapeFlow
  # checks their output against the endpoint's Coverage::Contract, which by
  # default flags an empty list).
  #
  #   parse(html) -> [record] | record
  #   follow_ups -> [FollowUp]                      # fetched after the page
  #   parse_page(html, follow_ups:) -> ParsedPage   # what ScrapeFlow calls
  #
  # parse_page wraps parse with no filters; a parser whose page also offers
  # search filters, or isn't a list, overrides it. `follow_ups` maps each
  # declared FollowUp#name to its response body, or nil when that request
  # failed; parsers that declare none ignore it.
  #
  # So a parser is more than a reader: each FollowUp it declares is one more
  # request to the site on every scrape of its endpoint (ScrapeFlow makes
  # them; the parser only says which). It lives here because the request is
  # knowledge about the page, like a selector. If a follow-up ever needs the
  # page's HTML to build its path, or is shared between parsers, split the
  # request side out rather than growing this interface.
  #
  # Impls: Nissei::SearchParser (Products + Filters), Nissei::HomeParser (a Home),
  # Booking::SearchParser (Properties). A parser is site-specific and chosen per
  # endpoint by its controller action.
  module Parser
    def parse(_html)
      raise NotImplementedError, "#{self.class} must implement #parse"
    end

    # The requests to make after the page, in order. None by default.
    def follow_ups = []

    def parse_page(html, follow_ups: {})
      ParsedPage.new(results: parse(html), filters: nil)
    end

    def lazy_first_selector_match(node, selectors)
      selectors.lazy.filter_map { |selector| node.at_css(selector) }.first
    end

    def first_selector_match(node, selectors)
      selectors.each do |selector|
        found = node.css(selector)
        return found if found.any?
      end
      Nokogiri::XML::NodeSet.new(node.document, [])
    end

    # Collapses runs of whitespace. Blank text is nil, never "": an element
    # that is present but empty holds no value, and a coverage check must be
    # able to count it as missing.
    def squish(text)
      squished = text&.gsub(/[[:space:]]+/, " ")&.strip
      squished unless squished.nil? || squished.empty?
    end
  end
end
