# frozen_string_literal: true

class Messages::VoiceCoreAttachmentTranscription
  def initialize(attachment, client: Telephony::VoiceCoreClient.new)
    @attachment = attachment
    @client = client
  end

  def perform
    Messages::VoiceCoreAttachmentSpool.new(@attachment).open do |spool|
      response = @client.transcribe(account_id: @attachment.account_id, job_id: spool.job_id, audio_filename: spool.audio_filename,
                                    channel_map: {}, is_phone_call: false)
      { 'text' => response.fetch('dialogue_turns').map { |turn| turn.fetch('text').strip }.join("\n"),
        'provenance' => { 'provider' => 'voicecore', 'model' => response.fetch('model_version') } }
    end
  end
end
