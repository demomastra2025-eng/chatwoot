# frozen_string_literal: true

require 'safe_fetch'

class Telephony::ExternalRecordingPlaybackProxy
  MAX_BYTES = 100.megabytes
  DEFAULT_OPEN_TIMEOUT = 3
  DEFAULT_READ_TIMEOUT = 12

  Result = Data.define(:data, :content_type, :filename)

  def self.fetch(url:, fallback_content_type:, fallback_filename:)
    new(url: url, fallback_content_type: fallback_content_type, fallback_filename: fallback_filename).fetch
  end

  def initialize(url:, fallback_content_type:, fallback_filename:)
    @url = url
    @fallback_content_type = fallback_content_type
    @fallback_filename = fallback_filename
  end

  def fetch
    SafeFetch.fetch(url, **safe_fetch_options) do |result|
      return Result.new(
        data: result.tempfile.read,
        content_type: result.content_type.presence || fallback_content_type,
        filename: fallback_filename
      )
    end
  end

  private

  attr_reader :url, :fallback_content_type, :fallback_filename

  def safe_fetch_options
    {
      allowed_content_type_prefixes: ['audio/'],
      allowed_content_types: ['application/octet-stream'],
      max_bytes: MAX_BYTES,
      open_timeout: timeout_value('TELEPHONY_EXTERNAL_RECORDING_OPEN_TIMEOUT_SECONDS', DEFAULT_OPEN_TIMEOUT),
      read_timeout: timeout_value('TELEPHONY_EXTERNAL_RECORDING_READ_TIMEOUT_SECONDS', DEFAULT_READ_TIMEOUT),
      headers: { 'User-Agent' => 'OneLink-RecordingPlayback/1.0' }
    }
  end

  def timeout_value(env_key, default)
    value = ENV.fetch(env_key, default).to_i
    value.positive? ? value : default
  end
end
