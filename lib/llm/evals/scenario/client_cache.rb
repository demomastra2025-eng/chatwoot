# frozen_string_literal: true

require 'digest'
require 'json'

class Llm::Evals::Scenario::ClientCache
  class CacheMiss < StandardError; end

  DEFAULT_NAMESPACE = 'scenario_client'
  MODES = %w[read_write read_only write_only off].freeze

  attr_reader :cache_key, :namespace, :mode

  def initialize(**attributes)
    @cache_key = attributes[:cache_key].to_s.presence
    @store = attributes[:store]
    @namespace = attributes.fetch(:namespace, DEFAULT_NAMESPACE).to_s
    @mode = normalize_mode(attributes.fetch(:mode, :read_write))
  end

  def fetch(request)
    return yield(request) unless enabled?

    key = key_for(request)
    return @store.read(key) if read_enabled? && @store.exist?(key)
    raise CacheMiss, "scenario client cache miss: #{key}" unless block_given?

    response = yield(request)
    @store.write(key, response) if write_enabled?
    response
  end

  def enabled?
    @store.present? && cache_key.present? && mode != 'off'
  end

  def read_enabled?
    enabled? && %w[read_write read_only].include?(mode)
  end

  private

  def write_enabled?
    enabled? && %w[read_write write_only].include?(mode)
  end

  def normalize_mode(value)
    normalized_mode = value.to_s
    MODES.include?(normalized_mode) ? normalized_mode : 'read_write'
  end

  def key_for(request)
    payload = canonical_json(request)
    digest = Digest::SHA256.hexdigest(payload)

    ['llm_evals', 'scenario', namespace, cache_key, digest].join(':')
  end

  def canonical_json(value)
    JSON.generate(deep_sort(value))
  end

  def deep_sort(value)
    case value
    when Hash
      value.to_h.deep_symbolize_keys.sort_by { |key, _| key.to_s }.to_h.transform_values { |child| deep_sort(child) }
    when Array
      value.map { |child| deep_sort(child) }
    else
      value
    end
  end
end
