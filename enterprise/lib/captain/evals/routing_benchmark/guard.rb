# frozen_string_literal: true

require 'uri'
require 'net/http'

class Captain::Evals::RoutingBenchmark::Guard
  DATABASE_SUFFIX = /_(benchmark|test)\z/
  LOOPBACK_HOSTS = %w[127.0.0.1 ::1 localhost].freeze

  module NetHttpRestriction
    private

    def connect
      unless address == 'openrouter.ai' && use_ssl?
        raise ArgumentError, 'Benchmark HTTP is restricted to OpenRouter'
      end

      super
    end
  end

  def self.check!(database_name: nil,
                  redis_url: ENV.fetch('REDIS_URL', nil), benchmark_redis_url: ENV.fetch('BENCHMARK_REDIS_URL', nil))
    raise ArgumentError, 'Production is forbidden' if Rails.env.production?
    database_name ||= ActiveRecord::Base.connection.select_value('SELECT current_database()')
    raise ArgumentError, 'An isolated benchmark or test database is required' unless database_name.to_s.match?(DATABASE_SUFFIX)
    raise ArgumentError, 'A separate benchmark Redis URL is required' if redis_url.blank? || redis_url != benchmark_redis_url

    uri = URI.parse(redis_url)
    valid = %w[redis rediss].include?(uri.scheme) && LOOPBACK_HOSTS.include?(uri.host) &&
            uri.path.to_s.match?(%r{\A/[1-9]\d*\z})
    raise ArgumentError, 'Benchmark Redis must use a nondefault loopback database' unless valid

    true
  end

  def self.restrict_http!
    Net::HTTP.prepend(NetHttpRestriction) unless Net::HTTP.ancestors.include?(NetHttpRestriction)
    require 'webmock'
    WebMock.enable!
    WebMock.disable_net_connect!(allow: %r{\Ahttps://openrouter\.ai(?::443)?/})
  rescue LoadError
    # Production bundles may omit the test-only WebMock gem; Net::HTTP stays restricted.
    true
  end
end
