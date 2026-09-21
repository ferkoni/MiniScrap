require "securerandom"

# Specs tagged :redis run only when REDIS_URL points at a Redis server (CI
# provides one; locally: `docker run -d -p 127.0.0.1:6380:6379 redis:7-alpine`
# and REDIS_URL=redis://127.0.0.1:6380/15).
module RedisHelper
  # A backend in a namespace of its own, so examples never see each other's
  # keys. Pass the same namespace to model several processes sharing Redis.
  def redis_backend(namespace: redis_namespace, **options)
    Scraper::ClearanceStore::RedisBackend.new(redis: Redis.new(url: ENV.fetch("REDIS_URL")), namespace: namespace, poll_interval: 0.01, **options)
  end

  def redis_namespace
    @redis_namespace ||= "spec-#{SecureRandom.hex(6)}"
  end
end

RSpec.configure do |config|
  config.include RedisHelper, :redis
end
