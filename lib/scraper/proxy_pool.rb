module Scraper
  # The egress proxies requests go out through, handed out round-robin (thread
  # safe). Empty means no proxy: requests leave from the host's own IP.
  #
  # A Cloudflare clearance is bound to the egress IP that solved it, so every
  # proxy gets its own clearance — the proxy is part of the ClearanceKey, and
  # both the fetch and the solve go through it.
  class ProxyPool
    attr_reader :proxies

    # "http://user:pw@a:8080, http://b:8080" -> a pool of two.
    def self.parse(list)
      new(list.to_s.split(",").map(&:strip).reject(&:empty?))
    end

    def initialize(proxies)
      @proxies = proxies.freeze
      @turn = Concurrent::AtomicFixnum.new(-1)
    end

    def next
      @proxies[@turn.increment % @proxies.size] unless @proxies.empty?
    end
  end
end
