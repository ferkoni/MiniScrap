module Scraper
  module Coverage
    # One JSON path: dot-separated keys, each optionally followed by `[]` for
    # "every element of this array", e.g. "results[].products[].title". The
    # last segment names a value, so it takes no `[]`. A malformed path raises
    # when the Contract is built, at class load, never per request.
    class Path
      Segment = Data.define(:key, :each)
      Match = Data.define(:path, :value)

      SEGMENT = /\A([a-z_][a-z0-9_]*)(\[\])?\z/

      attr_reader :source, :segments

      def initialize(source)
        @source = source
        @segments = source.split(".", -1).map do |part|
          match = SEGMENT.match(part) or raise ArgumentError, "invalid coverage path: #{source.inspect}"
          Segment.new(key: match[1], each: !match[2].nil?)
        end
        raise ArgumentError, "coverage path must end in a key: #{source.inspect}" if segments.empty? || segments.last.each
      end

      # Does resolving the path fan out over an array? With `[]`, zero matches
      # means an empty array, which a rule on that array reports.
      def each?
        segments.any?(&:each)
      end

      # Every value the path reaches, with its concrete path
      # ("results[3].products"). A missing key, or `[]` over something that is
      # not an array, reaches nothing.
      def matches(data)
        segments.reduce([Match.new(path: nil, value: data)]) do |matches, segment|
          matches.flat_map { |match| step(match, segment) }
        end
      end

      def to_s = source

      private

      def step(match, segment)
        return [] unless match.value.is_a?(Hash)

        found, value = Coverage.lookup(match.value, segment.key)
        return [] unless found

        path = match.path ? "#{match.path}.#{segment.key}" : segment.key
        return [Match.new(path: path, value: value)] unless segment.each
        return [] unless value.is_a?(Array)

        value.each_with_index.map { |element, index| Match.new(path: "#{path}[#{index}]", value: element) }
      end
    end
  end
end
