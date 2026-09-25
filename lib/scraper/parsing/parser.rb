module Scraper
  # Interface for turning a cleared HTML body into a list of records, each
  # responding to #to_h (ScrapeFlow flags an empty list "zero_results").
  #
  #   parse(html) -> [record]
  #
  # Impls: NisseiSearchParser (product Results), NisseiHomeParser (Sections). A parser is site-specific and owned by a Site.
  module Parser
    def parse(_html)
      raise NotImplementedError, "#{self.class} must implement #parse"
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

    # Collapses runs of whitespace
    def squish(text)
      text&.gsub(/[[:space:]]+/, " ")&.strip
    end
  end
end
