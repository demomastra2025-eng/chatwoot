# frozen_string_literal: true

require 'net/http'
require 'uri'

class Integrations::KaspiPay::AppVersionResolver
  FALLBACK_VERSION = '26.1029'
  ITUNES_LOOKUP_URL = 'https://itunes.apple.com/lookup?id=1262997215&country=kz'
  REDIS_CACHE_KEY = 'kaspi_pay:app_store_version:v1'
  CACHE_TTL_SECONDS = 6 * 3600
  NEGATIVE_CACHE_TTL_SECONDS = 10 * 60
  NEGATIVE_SENTINEL = '__fallback__'
  VERSION_FORMAT = /\A\d+(?:\.\d+)+\z/

  class << self
    def resolve(force_refresh: false, allow_network: !Rails.env.test?)
      unless force_refresh
        cached = read_cache
        return FALLBACK_VERSION if cached == NEGATIVE_SENTINEL
        return cached if not_older_than_fallback?(cached)
      end

      return FALLBACK_VERSION unless allow_network

      fetch_and_cache_live_version
    end

    def not_older_than_fallback?(candidate)
      val = candidate.to_s.strip
      return false unless val.match?(VERSION_FORMAT)

      Gem::Version.new(val) >= Gem::Version.new(FALLBACK_VERSION)
    rescue ArgumentError
      false
    end

    def sanitize_saved_version(candidate)
      candidate if not_older_than_fallback?(candidate)
    end

    private

    def fetch_and_cache_live_version
      live = fetch_app_store_version
      if not_older_than_fallback?(live)
        write_cache(live, CACHE_TTL_SECONDS)
        return live
      end

      write_cache(NEGATIVE_SENTINEL, NEGATIVE_CACHE_TTL_SECONDS)
      FALLBACK_VERSION
    rescue StandardError => e
      Rails.logger.warn("[KaspiPay::AppVersionResolver] Fallback to #{FALLBACK_VERSION}: #{e.class}: #{e.message}")
      write_cache(NEGATIVE_SENTINEL, NEGATIVE_CACHE_TTL_SECONDS)
      FALLBACK_VERSION
    end

    def fetch_app_store_version
      uri = URI.parse(ITUNES_LOOKUP_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 2
      http.read_timeout = 2
      resp = http.request(Net::HTTP::Get.new(uri.request_uri))
      return nil unless resp.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(resp.body.to_s)
      parsed.dig('results', 0, 'version').to_s.strip.presence
    end

    def read_cache
      ::Redis::Alfred.get(REDIS_CACHE_KEY)
    rescue StandardError
      nil
    end

    def write_cache(value, ttl)
      ::Redis::Alfred.setex(REDIS_CACHE_KEY, value, ttl)
    rescue StandardError
      nil
    end
  end
end
