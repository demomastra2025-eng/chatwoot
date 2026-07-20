class Telephony::VoiceMessageRecordingSyncService
  LOCAL_RECORDING_PREFIX = 'voice-recordings/'.freeze

  def initialize(call_session:)
    @call_session = call_session
  end

  def perform
    call_session.with_lock do
      call_session.reload
      sync_exact_message
    end
  end

  private

  attr_reader :call_session

  def sync_exact_message
    message = call_session.logical_group_voice_message
    return if message.blank?

    message.with_lock { sync_message(message) }
  end

  def sync_message(message)
    attributes = normalized_content_attributes(message)
    data = normalized_data(attributes)
    return message unless recording_already_present?(data)

    recording = authoritative_recording
    storage_key = recording_storage_key(recording)
    return message unless storage_key&.start_with?(LOCAL_RECORDING_PREFIX)

    recording_url = Telephony::CallRecordingPlaybackUrl.path_for(call_session, storage_key: storage_key)
    data['recording_ref'] = storage_key
    data['recording_url'] = recording_url
    data['recording'] = recording.merge(
      'recording_ref' => storage_key,
      'storage_key' => storage_key,
      'recording_url' => recording_url
    )
    attributes['data'] = data
    message.update!(content_attributes: attributes) if message.content_attributes != attributes
    message
  end

  def normalized_content_attributes(message)
    attributes = message.content_attributes
    attributes = JSON.parse(attributes) if attributes.is_a?(String)
    attributes.respond_to?(:to_h) ? attributes.to_h.deep_stringify_keys : {}
  rescue JSON::ParserError
    {}
  end

  def normalized_data(attributes)
    data = attributes['data']
    data.is_a?(Hash) ? data.deep_stringify_keys : {}
  end

  def recording_already_present?(data)
    data['recording_ref'].present? || data['recording_url'].present? || data['recording'].is_a?(Hash)
  end

  def authoritative_recording
    recording = call_session.metadata.to_h['recording']
    recording.is_a?(Hash) ? recording.deep_stringify_keys : {}
  end

  def recording_storage_key(recording)
    recording['storage_key'].presence || recording['recording_ref'].presence || call_session.recording_ref.presence
  end
end
