# frozen_string_literal: true

require 'net/http'
require 'timeout'
require 'uri'

# Internal, deployment-configured batch ASR. A selected local provider never falls back to an LLM.
class Telephony::VoiceCoreClient
  REQUEST_SCHEMA = 'onelink.voicecore.request.v1'
  RESPONSE_SCHEMA = 'onelink.voicecore.response.v1'
  # SHA256 of canonical services/onelink-voicecore/model-manifest.json, independently approved with this package.
  APPROVED_MANIFEST_SHA256 = '1f18b6338ccb72b202aa89c942b3989775dc93af137e201da21846a676b6095e'
  MAX_REQUEST_BYTES = 16.kilobytes
  MAX_RESPONSE_BYTES = 2.megabytes
  MAX_DURATION_SECONDS = 1800
  RESPONSE_KEYS = %w[schema account_id job_id text dialogue_turns language duration_sec channels channel_status model_version].freeze
  TURN_KEYS = %w[speaker channel start_sec end_sec text].freeze
  LANGUAGES = %w[ru kk en mixed unknown].freeze

  class Error < StandardError
    attr_reader :code, :retryable

    def initialize(code = 'unavailable', retryable: false)
      @code = code
      @retryable = retryable
      super('VoiceCore transcription unavailable')
    end
  end

  class RetryableError < Error; end

  def self.selected_for?(account)
    return false unless ENV.fetch('ONELINK_VOICECORE_ENABLED', '') == 'true'

    values = ENV.fetch('ONELINK_VOICECORE_ACCOUNT_IDS', '').split(',', -1).map(&:strip)
    raise Error, 'invalid_configuration' unless values.any? && values.all? { |value| value.match?(/\A[1-9]\d*\z/) }

    values.include?(account.id.to_s)
  end

  def transcribe(account_id:, job_id:, audio_filename:, channel_map:)
    payload = { schema: REQUEST_SCHEMA, account_id: account_id, job_id: job_id, audio_filename: audio_filename,
                channel_map: channel_map, is_phone_call: true }
    validate_request!(payload)
    body = JSON.generate(payload)
    raise Error, 'request_too_large' if body.bytesize > MAX_REQUEST_BYTES

    response = request(body)
    validate_response!(response, payload)
    response
  rescue JSON::ParserError, JSON::GeneratorError
    raise Error, 'invalid_json'
  rescue Timeout::Error, IOError, SystemCallError, SocketError
    raise Error.new('unavailable', retryable: true)
  end

  private

  def endpoint
    uri = URI.parse(ENV.fetch('ONELINK_VOICECORE_URL', ''))
    valid = uri.instance_of?(URI::HTTP) && %w[127.0.0.1 ::1].include?(uri.hostname) &&
            [uri.userinfo, uri.query, uri.fragment].all?(&:nil?) && ['', '/', '/transcribe'].include?(uri.path)
    raise Error, 'invalid_configuration' unless valid

    uri.path = '/transcribe'
    uri
  rescue URI::InvalidURIError
    raise Error, 'invalid_configuration'
  end

  def token
    value = ENV.fetch('ONELINK_VOICECORE_TOKEN', '')
    raise Error, 'invalid_configuration' if value.bytesize < 32 || value.match?(/[\r\n]/)

    value
  end

  def request(body)
    uri = endpoint
    authorization = token
    http = Net::HTTP.new(uri.hostname, uri.port, nil) # Do not inherit HTTP_PROXY for local audio requests.
    http.open_timeout = 2
    http.read_timeout = 120
    http.write_timeout = 10
    http.max_retries = 0
    message = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json', 'Authorization' => "Bearer #{authorization}")
    message.body = body
    raw = Timeout.timeout(130) { read_response(http, message) }
    JSON.parse(raw)
  end

  def read_response(http, message)
    body = +''
    http.request(message) do |response|
      code = response.code.to_i
      raise Error.new('http_error', retryable: [429, 503, 504].include?(code)) unless code == 200
      raise Error, 'invalid_content_type' unless response['content-type'].to_s.split(';').first == 'application/json'
      raise Error, 'response_too_large' if response['content-length'].to_i > MAX_RESPONSE_BYTES

      response.read_body do |chunk|
        raise Error, 'response_too_large' if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES

        body << chunk
      end
    end
    body
  end

  def validate_request!(payload)
    valid = payload[:account_id].is_a?(Integer) && payload[:account_id].positive? &&
            valid_job_id?(payload[:job_id]) &&
            payload[:audio_filename].is_a?(String) && payload[:audio_filename].match?(/\Aaudio\.(wav|mp3|ogg|m4a|flac)\z/) &&
            valid_channel_map?(payload[:channel_map])
    raise Error, 'invalid_request' unless valid
  end

  def valid_channel_map?(map)
    [{}, { '0' => 'operator', '1' => 'client' }, { '0' => 'client', '1' => 'operator' }].include?(map)
  end

  def valid_job_id?(value)
    value.is_a?(String) && value.match?(/\A[0-9a-f]{32}\z/)
  end

  def validate_response!(data, payload)
    validate_response_shape!(data, payload)
    raise Error, 'unapproved_manifest' unless data['model_version'] == APPROVED_MANIFEST_SHA256

    validate_channels!(data, payload[:channel_map])
    data['dialogue_turns'].each { |turn| validate_turn!(turn, data, payload[:channel_map]) }
    raise Error, 'invalid_response' if data['dialogue_turns'].empty? != data['text'].strip.empty?
  end

  def validate_response_shape!(data, payload)
    raise Error, 'invalid_response' unless data.is_a?(Hash) && data.keys.sort == RESPONSE_KEYS.sort
    raise Error, 'invalid_response' unless valid_identity?(data, payload) && valid_content?(data) && valid_audio?(data)
  end

  def valid_identity?(data, payload)
    data['schema'] == RESPONSE_SCHEMA && data['account_id'].is_a?(Integer) && data['account_id'] == payload[:account_id] &&
      data['job_id'] == payload[:job_id] && data['model_version'].is_a?(String) && data['model_version'].match?(/\A[0-9a-f]{64}\z/)
  end

  def valid_content?(data)
    data['text'].is_a?(String) && data['text'].valid_encoding? && LANGUAGES.include?(data['language']) &&
      data['dialogue_turns'].is_a?(Array) && data['dialogue_turns'].length <= 10_000
  end

  def valid_audio?(data)
    data['channels'].is_a?(Integer) && [1, 2].include?(data['channels']) &&
      finite_seconds?(data['duration_sec']) && data['duration_sec'] <= MAX_DURATION_SECONDS
  end

  def validate_channels!(data, channel_map)
    expected = if data['channels'] == 1
                 'mono'
               elsif channel_map.empty?
                 'unmapped'
               else
                 'mapped'
               end
    raise Error, 'invalid_channels' if data['channel_status'] != expected || (expected == 'mono' && channel_map.any?)
  end

  def validate_turn!(turn, data, channel_map)
    raise Error, 'invalid_turn' unless turn.is_a?(Hash) && turn.keys.sort == TURN_KEYS.sort
    raise Error, 'invalid_turn' unless valid_turn_content?(turn, data) && valid_turn_timing?(turn, data)

    role = data['channel_status'] == 'mapped' ? channel_map.fetch(turn['channel'].to_s) : 'unknown'
    raise Error, 'invalid_speaker' unless turn['speaker'] == role
  end

  def valid_turn_content?(turn, data)
    turn['channel'].is_a?(Integer) && turn['channel'].between?(0, data['channels'] - 1) && turn['text'].is_a?(String) &&
      turn['text'].valid_encoding? && turn['text'].strip.present? && turn['text'].bytesize <= 32.kilobytes
  end

  def valid_turn_timing?(turn, data)
    finite_seconds?(turn['start_sec']) && finite_seconds?(turn['end_sec']) &&
      turn['start_sec'] <= turn['end_sec'] && turn['end_sec'] <= data['duration_sec'] + 0.1
  end

  def finite_seconds?(value)
    value.is_a?(Numeric) && value.finite? && value >= 0
  end
end
