# frozen_string_literal: true

require "redis"

module HopperSpec
  # Access to the test Redis. Never uses the default port so a developer's own
  # Redis on 6379 is untouched. Start one with `bin/test-redis` or docker compose.
  module RedisHelper
    DEFAULT_URL = "redis://127.0.0.1:6399/0"

    module_function

    def url = ENV.fetch("HOPPER_TEST_REDIS_URL", DEFAULT_URL)

    def new_connection = Redis.new(url: url)

    def available?
      return @available if defined?(@available)

      @available = begin
        new_connection.ping == "PONG"
      rescue Redis::BaseError, SystemCallError
        false
      end
    end

    def unavailable_message
      "test Redis not reachable at #{url}; run bin/test-redis or docker compose up, " \
        "or set HOPPER_TEST_REDIS_URL"
    end

    def build_id(prefix = "spec") = "#{prefix}-#{SecureRandom.hex(6)}"

    def keys(redis, build_id)
      pattern = RSpec::Hopper::Keys.new(build_id).pattern
      found = []
      redis.scan_each(match: pattern) { |k| found << k }
      found.sort
    end

    def ttls(redis, build_id)
      keys(redis, build_id).to_h { |k| [k, redis.pttl(k)] }
    end

    def delete_build(redis, build_id)
      ks = keys(redis, build_id)
      redis.del(*ks) if ks.any?
    end
  end
end
