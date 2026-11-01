# frozen_string_literal: true

require 'net/http'
require 'uri'

class Integrations::KaspiPay::AppVersionResolver
  FALLBACK_VERSION = '26.1029'
  FALLBACK_BUILD = '1116'
  ITUNES_LOOKUP_URL = 'https://itunes.apple.com/lookup?id=1262997215&country=kz'
  REDIS_CACHE_KEY = 'kaspi_pay:app_store_version:v1'
  REDIS_BUILD_CACHE_KEY = 'kaspi_pay:resolved_app_build:v1'
  CACHE_TTL_SECONDS = 6 * 3600
  BUILD_CACHE_TTL_SECONDS = 180 * 24 * 3600
  NEGATIVE_CACHE_TTL_SECONDS = 10 * 60
  NEGATIVE_SENTINEL = '__fallback__'
  VERSION_FORMAT = /\A\d+(?:\.\d+)+\z/
  BUILD_FORMAT = /\A\d{1,12}\z/
  BUILD_PROBE_STEPS = [1, 16, 64, 256, 1024, 4096, 16_384].freeze

  class << self
    def resolve(force_refresh: false, allow_network: !Rails.env.test?)
      cached = read_cache(REDIS_CACHE_KEY)
      unless force_refresh
        return FALLBACK_VERSION if cached == NEGATIVE_SENTINEL
        return cached if not_older_than_fallback?(cached)
      end

      prev_valid = not_older_than_fallback?(cached) ? cached : nil
      return prev_valid || FALLBACK_VERSION unless allow_network

      fetch_and_cache_live_version(prev_valid)
    end

    def resolve_build
      cached = read_cache(REDIS_BUILD_CACHE_KEY).to_s.strip
      valid_build_above_fallback?(cached) ? cached : FALLBACK_BUILD
    end

    def minimum_known_version
      cached = read_cache(REDIS_CACHE_KEY).to_s.strip
      not_older_than_fallback?(cached) ? cached : FALLBACK_VERSION
    end

    def minimum_known_build = resolve_build.to_i

    def not_older_than_fallback?(candidate) = not_older_than_version?(candidate, FALLBACK_VERSION)

    def not_older_than_version?(candidate, floor_version)
      val = candidate.to_s.strip
      return false unless val.match?(VERSION_FORMAT)

      Gem::Version.new(val) >= Gem::Version.new(floor_version)
    rescue ArgumentError
      false
    end

    def not_older_than_minimum_build?(candidate)
      val = candidate.to_s.strip
      val.match?(BUILD_FORMAT) && val.to_i >= minimum_known_build
    end

    def sanitize_saved_version(candidate)
      val = candidate.to_s.strip
      val if not_older_than_version?(val, minimum_known_version)
    end

    def sanitize_saved_build(candidate)
      val = candidate.to_s.strip
      val if not_older_than_minimum_build?(val)
    end

    def sanitize_format(key, candidate)
      val = candidate.to_s.strip
      val if val.match?(key == :version ? VERSION_FORMAT : BUILD_FORMAT)
    end

    def sanitize_overrides(version: nil, build: nil)
      { version: sanitize_saved_version(version), build: sanitize_saved_build(build) }.compact
    end

    def cache_resolved_build!(build)
      val = build.to_s.strip
      return resolve_build unless valid_build_above_fallback?(val)

      winner = [val.to_i, minimum_known_build].max.to_s
      write_cache(REDIS_BUILD_CACHE_KEY, winner, BUILD_CACHE_TTL_SECONDS)
      winner
    end

    def old_version_error?(err)
      err.code.to_s == 'OldVersionToUpdate' || err.details.to_s.include?('OldVersionToUpdate')
    end

    def resolve_retry_overrides(failed_version:, failed_build:, explicit_overrides: {})
      refreshed_ver = highest_valid_version(failed_version, explicit_overrides[:version], resolve(force_refresh: true))
      baseline_build = resolve_build
      check_floor = version_upgraded?(refreshed_ver, failed_version) || baseline_build != failed_build.to_s.strip
      new_build = discover_working_build!(current_build: baseline_build, version: refreshed_ver, check_current_build: check_floor)
      return nil if new_build.blank?

      explicit_overrides.merge(version: refreshed_ver, build: new_build)
    end

    def discover_working_build!(current_build:, version: FALLBACK_VERSION, check_current_build: false, &)
      cur_int = current_build.to_s.strip.to_i
      floor = [cur_int, minimum_known_build].max
      return cache_resolved_build!(floor) if (check_current_build || floor > cur_int) && probe_ok?(floor, version, &)

      bracket = bracket_working_build(floor, version, &)
      return nil unless bracket

      cache_resolved_build!(binary_search_build(bracket[0], bracket[1], version, &))
    end

    private

    def highest_valid_version(*candidates)
      valid = candidates.filter_map { |c| c.to_s.strip if not_older_than_fallback?(c) }
      valid.max_by { |v| Gem::Version.new(v) } || FALLBACK_VERSION
    end

    def version_upgraded?(candidate, previous)
      return false unless not_older_than_fallback?(candidate) && not_older_than_fallback?(previous)

      Gem::Version.new(candidate.to_s.strip) > Gem::Version.new(previous.to_s.strip)
    end

    def valid_build_above_fallback?(val)
      val.match?(BUILD_FORMAT) && val.to_i >= FALLBACK_BUILD.to_i
    end

    def bracket_working_build(failed_floor, version, &)
      low = failed_floor
      BUILD_PROBE_STEPS.each do |step|
        high = failed_floor + step
        return [low, high] if probe_ok?(high, version, &)

        low = high
      end
      nil
    end

    def binary_search_build(low, high, version, &)
      while high - low > 1
        mid = (low + high) / 2
        probe_ok?(mid, version, &) ? (high = mid) : (low = mid)
      end
      high.to_s
    end

    def probe_ok?(candidate_build, version, &probe)
      return yield(candidate_build.to_s, version) if probe

      default_entrance_probe(candidate_build.to_s, version)
    end

    def default_entrance_probe(candidate_build, version)
      ephemeral_device = Integrations::KaspiPay::Crypto.generate_device_identity
      Integrations::KaspiPay::ApiClient.new(device: ephemeral_device, app_overrides: { version: version, build: candidate_build }).auth_init
      true
    rescue Integrations::KaspiPay::ApiClient::ApiError => e
      return false if old_version_error?(e)

      raise
    end

    def fetch_and_cache_live_version(prev_valid = nil)
      live = fetch_app_store_version
      if not_older_than_version?(live, prev_valid || FALLBACK_VERSION)
        write_cache(REDIS_CACHE_KEY, live, CACHE_TTL_SECONDS)
        return live
      end
      fallback_live_version(prev_valid)
    rescue StandardError => e
      Rails.logger.warn("[KaspiPay::AppVersionResolver] Fallback to #{prev_valid || FALLBACK_VERSION}: #{e.class}: #{e.message}")
      fallback_live_version(prev_valid)
    end

    def fallback_live_version(prev_valid)
      return prev_valid if prev_valid.present?

      write_cache(REDIS_CACHE_KEY, NEGATIVE_SENTINEL, NEGATIVE_CACHE_TTL_SECONDS)
      FALLBACK_VERSION
    end

    def fetch_app_store_version
      uri = URI.parse(ITUNES_LOOKUP_URL)
      http = Net::HTTP.new(uri.host, uri.port).tap { |h| h.use_ssl = true }
      http.open_timeout = 2
      http.read_timeout = 2
      resp = http.request(Net::HTTP::Get.new(uri.request_uri))
      JSON.parse(resp.body.to_s).dig('results', 0, 'version').to_s.strip.presence if resp.is_a?(Net::HTTPSuccess)
    end

    def read_cache(key)
      ::Redis::Alfred.get(key)
    rescue StandardError
      nil
    end

    def write_cache(key, value, ttl)
      ::Redis::Alfred.setex(key, value, ttl)
    rescue StandardError
      nil
    end
  end
end
