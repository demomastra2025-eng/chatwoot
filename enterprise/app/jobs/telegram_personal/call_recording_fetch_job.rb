class TelegramPersonal::CallRecordingFetchJob < ApplicationJob
  queue_as :whatsapp_calls

  MIN_RECORDING_BYTES = 256

  discard_on ActiveRecord::RecordNotFound

  def perform(call_id)
    call = Call.telegram_personal.find(call_id)
    return finalize_attached_recording!(call) if call.recording.attached?
    return if call.media_session_id.blank? || call.inbox&.channel.blank?

    client = TelegramPersonal::GatewayClient.new(channel: call.inbox.channel)
    call_ref = call.media_session_id.presence || call.provider_call_id
    recording_data = fetch_recording(client, call_ref)
    return if recording_data.blank?

    attach_recording(call, recording_data)
    finalize_attached_recording!(call)
  end

  private

  def fetch_recording(client, call_ref)
    %w[combined customer agent].each do |side|
      data = download_recording(client, call_ref, side: side)
      return data if usable_recording?(data)
    end
    nil
  end

  def download_recording(client, call_ref, side:)
    client.download_call_recording!(call_ref: call_ref, side: side)
  rescue TelegramPersonal::GatewayClient::GatewayError => e
    raise unless e.http_status.to_i == 404

    Rails.logger.info "[TELEGRAM CALL] Recording not available for #{call_ref} side=#{side}: #{e.message}"
    nil
  end

  def usable_recording?(data)
    data.present? && data.bytesize >= MIN_RECORDING_BYTES
  end

  def attach_recording(call, recording_data)
    call.recording.attach(
      io: StringIO.new(recording_data.dup.force_encoding('BINARY')),
      filename: "telegram_call_#{call.id}_#{call.provider_call_id}.ogg",
      content_type: 'audio/ogg'
    )
  end

  def finalize_attached_recording!(call)
    TelegramPersonal::CallMessageBuilder.update_recording_url!(call: call)
    return unless call.transcript.blank? && call.account.call_transcriptions_enabled?

    Whatsapp::CallTranscriptionJob.perform_later(call.id)
  end
end
