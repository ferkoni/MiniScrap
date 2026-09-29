module Scraper
  module Coverage
    # What one endpoint's output must satisfy, as JSON paths (see Path):
    #
    # - non_empty: the array or object at the path has content. Under `[]` it
    #   applies to every element; an issue names the element by index.
    # - required: the field has a value on at least one item it applies to.
    #   Missing on every item is a broken selector; missing on some is data
    #   (a real card with no price).
    #
    # DEFAULT, for a site that declares nothing more, flags an empty parse.
    Contract = Data.define(:non_empty, :required) do
      def initialize(non_empty: [], required: [])
        super(
          non_empty: non_empty.map { |source| Path.new(source) }.freeze,
          required: required.map { |source| Path.new(source) }.freeze
        )
      end
    end

    Contract::DEFAULT = Contract.new(non_empty: %w[results])
  end
end
