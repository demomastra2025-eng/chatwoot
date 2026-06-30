# frozen_string_literal: true

require 'safe_fetch'

class Telephony::ExternalRecordingPlaybackProxy
  MAX_BYTES = 100.megabytes
  RANGE_CHUNK_BYTES = 24.kilobytes
  DEFAULT_OPEN_TIMEOUT = 3
  DEFAULT_READ_TIMEOUT = 12
  DEFAULT_RANGE_READ_TIMEOUT = 4

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
    return fetch_range_chunks if range_chunked_fetch?

    fetch_with_safe_fetch
  end

  private

  attr_reader :url, :fallback_content_type, :fallback_filename

  def fetch_with_safe_fetch
    SafeFetch.fetch(url, **safe_fetch_options) do |result|
      return Result.new(
        data: result.tempfile.read,
        content_type: result.content_type.presence || fallback_content_type,
        filename: fallback_filename
      )
    end
  end

  def fetch_range_chunks
    data = String.new(capacity: RANGE_CHUNK_BYTES, encoding: Encoding::BINARY)
    content_type = populate_range_buffer!(data)
    range_result(data, content_type)
  rescue SafeFetch::HttpError => e
    return range_result(data, content_type) if range_complete_after_416?(data, e)

    raise
  end

  def populate_range_buffer!(data)
    content_type = nil
    offset = 0

    loop do
      result = fetch_range_chunk(offset)
      chunk = result.data
      break if chunk.empty?

      append_range_chunk!(data, chunk)
      content_type ||= result.content_type.presence
      break if range_chunk_final?(chunk)

      offset += chunk.bytesize
    end

    content_type
  end

  def append_range_chunk!(data, chunk)
    data << chunk
    raise SafeFetch::FileTooLargeError, "exceeded #{MAX_BYTES} bytes" if data.bytesize > MAX_BYTES
  end

  def range_result(data, content_type)
    raise SafeFetch::FetchError, 'empty recording response' if data.empty?

    Result.new(
      data: data,
      content_type: content_type.presence || fallback_content_type,
      filename: fallback_filename
    )
  end

  def range_chunk_final?(chunk)
    chunk.bytesize < RANGE_CHUNK_BYTES
  end

  def range_complete_after_416?(data, error)
    !data.empty? && error.message.start_with?('416 ')
  end

  def fetch_range_chunk(offset)
    range_end = offset + RANGE_CHUNK_BYTES - 1

    SafeFetch.fetch(
      url,
      **safe_fetch_options, max_bytes: RANGE_CHUNK_BYTES,
                            read_timeout: timeout_value(
                              'TELEPHONY_EXTERNAL_RECORDING_RANGE_READ_TIMEOUT_SECONDS',
                              DEFAULT_RANGE_READ_TIMEOUT
                            ),
                            headers: safe_fetch_headers.merge(
                              'Range' => "bytes=#{offset}-#{range_end}"
                            )
    ) do |result|
      return Result.new(
        data: result.tempfile.read,
        content_type: result.content_type.presence || fallback_content_type,
        filename: fallback_filename
      )
    end
  end

  def range_chunked_fetch?
    Telephony::ExternalRecordingPlaybackPolicy.proxy?(url)
  end

  def safe_fetch_options
    {
      allowed_content_type_prefixes: ['audio/'],
      allowed_content_types: ['application/octet-stream'],
      max_bytes: MAX_BYTES,
      open_timeout: timeout_value('TELEPHONY_EXTERNAL_RECORDING_OPEN_TIMEOUT_SECONDS', DEFAULT_OPEN_TIMEOUT),
      read_timeout: timeout_value('TELEPHONY_EXTERNAL_RECORDING_READ_TIMEOUT_SECONDS', DEFAULT_READ_TIMEOUT),
      headers: safe_fetch_headers
    }
  end

  def safe_fetch_headers
    { 'User-Agent' => 'OneLink-RecordingPlayback/1.0' }
  end

  def timeout_value(env_key, default)
    value = ENV.fetch(env_key, default).to_i
    value.positive? ? value : default
  end
end
