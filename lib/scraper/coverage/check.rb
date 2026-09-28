module Scraper
  module Coverage
    # Runs a Contract over one scrape's data (see Coverage).
    #
    # Coverage walks every key: `present` counts the objects whose value isn't
    # missing, out of `of` objects that have the key; arrays add `count`, their
    # elements summed across every parent. Counts aggregate across parents, so
    # "results[].products[].price" is over every section's products.
    #
    # Issues, in contract order:
    # - { code: "empty", path: } for each non_empty match that is missing, or
    #   for the declared path itself when it reaches nothing (a contract only
    #   names paths its endpoint returns, so absent means broken). A path
    #   through `[]` that reaches nothing crossed an empty array, which that
    #   array's own rule reports.
    # - { code: "missing_field", path:, present: 0, of: } for each required
    #   path missing on every item. With no items at all it is skipped: the
    #   empty parent is already reported, once.
    class Check
      def initialize(contract)
        @contract = contract
      end

      def call(data)
        Report.new(coverage: coverage(data), issues: empties(data) + missing_fields(data))
      end

      private

      def coverage(data)
        {}.tap { |entries| walk(data, nil, entries) }
      end

      def walk(hash, prefix, entries)
        hash.each do |key, value|
          path = prefix ? "#{prefix}.#{key}" : key.to_s
          entry = entries[path] ||= value.is_a?(Array) ? { "count" => 0, "present" => 0, "of" => 0 } : { "present" => 0, "of" => 0 }
          entry["of"] += 1
          entry["present"] += 1 unless Coverage.missing?(value)

          case value
          when Hash then walk(value, path, entries)
          when Array
            entry["count"] = entry.fetch("count", 0) + value.size
            value.each { |element| walk(element, "#{path}[]", entries) if element.is_a?(Hash) }
          end
        end
      end

      def empties(data)
        @contract.non_empty.flat_map do |path|
          matches = path.matches(data)
          next(path.each? ? [] : [empty(path.source)]) if matches.empty?

          matches.select { |match| Coverage.missing?(match.value) }.map { |match| empty(match.path) }
        end
      end

      def missing_fields(data)
        @contract.required.filter_map do |path|
          values = path.matches(data).map(&:value)
          next if values.empty? || !values.all? { |value| Coverage.missing?(value) }

          { "code" => "missing_field", "path" => path.source, "present" => 0, "of" => values.size }
        end
      end

      def empty(path)
        { "code" => "empty", "path" => path }
      end
    end
  end
end
