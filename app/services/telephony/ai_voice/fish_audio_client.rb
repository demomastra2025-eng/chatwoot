class Telephony::AiVoice::FishAudioClient
  BASE_URL = 'https://api.fish.audio'.freeze
  REQUEST_TIMEOUT = 60
  OPEN_TIMEOUT = 10

  class Error < StandardError
    attr_reader :http_status

    def initialize(message, http_status: nil)
      super(message)
      @http_status = http_status
    end
  end

  class ConfigurationError < Error; end
  class NotFoundError < Error; end

  def initialize(api_key: nil, connection: nil)
    @api_key = (api_key.nil? ? configured_api_key : api_key).to_s
    @connection = connection || build_connection
  end

  def create_model(title:, upload:, transcript: nil)
    ensure_configured!

    payload = {
      type: 'tts',
      title: title,
      train_mode: 'fast',
      visibility: 'private',
      enhance_audio_quality: 'true',
      voices: Faraday::Multipart::FilePart.new(
        upload.tempfile,
        upload.content_type.presence || 'application/octet-stream',
        upload.original_filename
      )
    }
    payload[:texts] = transcript if transcript.present?

    parse(connection.post('/model', payload) { |request| authorize(request) })
  rescue Faraday::Error, IOError, SystemCallError => e
    raise Error, "Fish Audio request failed: #{e.class}"
  end

  def model(provider_model_id)
    ensure_configured!
    parse(connection.get("/model/#{provider_model_id}") { |request| authorize(request) })
  rescue Faraday::Error, IOError, SystemCallError => e
    raise Error, "Fish Audio request failed: #{e.class}"
  end

  def delete_model(provider_model_id)
    ensure_configured!
    response = connection.delete("/model/#{provider_model_id}") { |request| authorize(request) }
    return true if response.status.to_i.between?(200, 299)

    parse(response)
  rescue Faraday::Error, IOError, SystemCallError => e
    raise Error, "Fish Audio request failed: #{e.class}"
  end

  private

  attr_reader :api_key, :connection

  def configured_api_key
    ENV.fetch('ONELINK_AI_VOICE_PIPECAT_FISH_API_KEY', nil).presence ||
      ENV.fetch('FISH_AUDIO_API_KEY', nil).presence ||
      ENV.fetch('FISH_API_KEY', nil)
  end

  def build_connection
    Faraday.new(url: BASE_URL) do |faraday|
      faraday.request :multipart
      faraday.request :url_encoded
      faraday.options.timeout = REQUEST_TIMEOUT
      faraday.options.open_timeout = OPEN_TIMEOUT
    end
  end

  def authorize(request)
    request.headers['Authorization'] = "Bearer #{api_key}"
    request.headers['Accept'] = 'application/json'
  end

  def ensure_configured!
    raise ConfigurationError, 'Fish Audio is not configured' if api_key.blank?
  end

  def parse(response)
    data = JSON.parse(response.body.presence || '{}')
    return data if response.status.to_i.between?(200, 299)

    error_class = response.status.to_i == 404 ? NotFoundError : Error
    raise error_class.new('Fish Audio rejected the request', http_status: response.status.to_i)
  rescue JSON::ParserError
    raise Error.new('Fish Audio returned an invalid response', http_status: response.status.to_i)
  end
end
