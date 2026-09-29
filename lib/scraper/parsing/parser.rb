module Scraper
  # Interface for turning a cleared HTML body into a list of records, each
  # responding to #to_h (ScrapeFlow checks their output against the site's
  # Coverage::Contract, which by default flags an empty list).
  #
  #   parse(html) -> [record]
  #   parse_page(html) -> ParsedPage   # what ScrapeFlow calls
  #
  # parse_page wraps parse with no filters; a parser whose page also offers
  # search filters overrides it.
  #
  # Impls: Nissei::SearchParser (Products + Filters), Nissei::HomeParser (Sections),
  # Booking::SearchParser (Properties). A parser is site-specific and owned by a Site.
  module Parser
    def parse(_html)
      raise NotImplementedError, "#{self.class} must implement #parse"
    end

    def parse_page(html)
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
