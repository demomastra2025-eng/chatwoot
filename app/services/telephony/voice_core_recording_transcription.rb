# frozen_string_literal: true

class Telephony::VoiceCoreRecordingTranscription
  OPERATOR_ROLES = %w[user_audio operator agent].freeze
  CLIENT_ROLES = %w[peer_audio caller customer client].freeze

  def initialize(call_session, client: Telephony::VoiceCoreClient.new)
    @call_session = call_session
    @client = client
  end

  def perform
    Telephony::VoiceCoreRecordingSpool.new(@call_session).open do |spool|
      response = @client.transcribe(account_id: @call_session.account_id, job_id: spool.job_id,
                                    audio_filename: spool.audio_filename, channel_map: channel_map)
      result_for(response)
    end
  end

  private

  def channel_map
    map = @call_session.metadata.to_h['recording'].to_h['channel_map']
    return {} unless map.is_a?(Hash)
    return {} if map.key?('0') && map.key?('2')

    roles = roles_for(map)
    return {} unless roles.all?(&:one?) && roles.flatten.sort == %w[client operator]

    { '0' => roles[0].first, '1' => roles[1].first }
  end

  def roles_for(map)
    channel_aliases(map).map { |keys| keys.filter_map { |key| canonical_role(map[key]) if map.key?(key) }.uniq }
  end

  def channel_aliases(map)
    if map.key?('0')
      [%w[0 channel_1 left FL c0], %w[1 channel_2 right FR c1]]
    else
      [%w[1 channel_1 left FL c0], %w[2 channel_2 right FR c1]]
    end
  end

  def canonical_role(role)
    return 'operator' if OPERATOR_ROLES.include?(role)
    return 'client' if CLIENT_ROLES.include?(role)

    'unknown'
  end

  def result_for(response)
    turns = response.fetch('dialogue_turns')
    native = Telephony::CallTranscript.parse({ 'transcript_items' => turns }.to_json)
    if turns.empty?
      native['summary'] = 'Речь в записи не обнаружена.'
      native['outcome'] = 'no_answer'
    end
    native.merge(
      'voicecore' => response.slice('dialogue_turns', 'language', 'duration_sec', 'channels', 'channel_status', 'model_version'),
      'provider' => 'voicecore', 'model' => response.fetch('model_version'),
      'audio_probe' => { 'channels' => response.fetch('channels'), 'duration_seconds' => response.fetch('duration_sec') }
    )
  end
end
