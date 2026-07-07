module Scraper
  # Interface for turning a cleared HTML body into product Results.
  #
  #   parse(html) -> [Result]
  #
  # Impls: NisseiParser. A parser is site-specific and owned by a Site.
  module Parser
    def parse(_html)
      raise NotImplementedError, "#{self.class} must implement #parse"
    end
  end
end
