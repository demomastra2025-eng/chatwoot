# frozen_string_literal: true

module Concerns::CaptainCustomToolHttpOptions
  extend ActiveSupport::Concern

  RETRYABLE_HTTP_STATUSES = [408, 425, 429, 500, 502, 503, 504].freeze
  PAGINATION_MODES = %w[page_parameter next_url].freeze
  PATH_FORMAT = /\A[a-zA-Z0-9_-]+(?:\.[a-zA-Z0-9_-]+)*\z/
  QUERY_PARAMETER_FORMAT = /\A[a-zA-Z_][a-zA-Z0-9_.\[\]-]*\z/
  DEFAULTS = {
    'timeout' => {
      'open_seconds' => 10,
      'read_seconds' => 30
    },
    'retry' => {
      'enabled' => false,
      'max_attempts' => 2,
      'backoff_ms' => 250,
      'statuses' => [502, 503, 504]
    },
    'redirects' => {
      'enabled' => false,
      'max_redirects' => 3
    },
    'idempotency' => {
      'enabled' => false
    },
    'pagination' => {
      'enabled' => false,
      'mode' => 'page_parameter',
      'parameter_name' => 'page',
      'start_page' => 1,
      'max_pages' => 10,
      'interval_ms' => 0,
      'items_path' => nil,
      'next_url_path' => nil
    },
    'batching' => {
      'enabled' => false,
      'items_parameter' => nil,
      'batch_size' => 50,
      'interval_ms' => 0
    }
  }.freeze

  included do
    before_validation :normalize_http_options
    validate :validate_http_options
  end

  def effective_http_options
    DEFAULTS.deep_dup.deep_merge(normalized_http_options_source)
  end

  def http_option(section, key)
    effective_http_options.dig(section.to_s, key.to_s)
  end

  private

  def normalize_http_options
    self.http_options = Captain::CustomToolHttpOptionsNormalizer.new(http_options).call
  end

  def normalized_http_options_source
    raw_options = http_options.respond_to?(:to_h) ? http_options.to_h : {}
    raw_options.deep_stringify_keys
  end

  def validate_http_options
    Captain::CustomToolHttpOptionsValidator.new(self).call
  end
end
