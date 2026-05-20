require 'open3'
require 'tempfile'
require 'timeout'

class Whatsapp::CallRecordingFetchJob < ApplicationJob
  queue_as :whatsapp_calls

  MIN_RECORDING_BYTES = 512
  MIX_TIMEOUT = 8.seconds

  retry_on Whatsapp::MediaServerClient::ConnectionError, wait: 5.seconds, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(call_id)
    call = Call.find(call_id)
    return finalize_attached_recording!(call) if call.recording.attached?
    return if call.media_session_id.blank?

    client = Whatsapp::MediaServerClient.new

    # combined.ogg is only produced when the media-server session terminates
    # (ffmpeg mix runs in Recorder.Finalize). For calls that ended via Meta's
    # terminate webhook — not agent hang-up — nothing has triggered Finalize
    # yet. Call terminate first; it's idempotent on the server. In production
    # the media-server can still time out while finalizing; in that case we
    # fall back to already-written side recordings below.
    safe_terminate(client, call.media_session_id)

    recording_data = fetch_recording(client, call.media_session_id)
    return if recording_data.blank?

    attach_recording(call, recording_data)
    finalize_attached_recording!(call)
  end

  private

  def finalize_attached_recording!(call)
    Whatsapp::CallMessageBuilder.update_recording_url!(call: call)
    Whatsapp::CallTranscriptionJob.perform_later(call.id) if call.transcript.blank?
  end

  def safe_terminate(client, session_id)
    client.terminate_session(session_id)
  rescue Whatsapp::MediaServerClient::SessionError, Whatsapp::MediaServerClient::ConnectionError => e
    Rails.logger.info "[WHATSAPP CALL] terminate_session during fetch (#{session_id}): #{e.message}"
  end

  def fetch_recording(client, session_id)
    combined = download_recording(client, session_id)
    return combined if usable_recording?(combined)

    side_recordings = %i[customer agent].filter_map do |side|
      data = download_recording(client, session_id, side: side)
      { side: side, data: data } if usable_recording?(data)
    end

    return if side_recordings.blank?
    return side_recordings.first[:data] if side_recordings.one?

    mix_side_recordings(session_id, side_recordings) || largest_recording(side_recordings)
  end

  def download_recording(client, session_id, side: nil)
    side ? client.download_recording(session_id, side: side) : client.download_recording(session_id)
  rescue Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.warn "[WHATSAPP CALL] Recording not available for session #{session_id} side=#{side || 'combined'}: #{e.message}"
    nil
  end

  def usable_recording?(data)
    data.present? && data.bytesize >= MIN_RECORDING_BYTES
  end

  def mix_side_recordings(session_id, side_recordings)
    inputs = recording_tempfiles(session_id, side_recordings)
    output = output_tempfile(session_id)
    mixed = run_ffmpeg_mix(session_id, inputs, output)
    usable_recording?(mixed) ? mixed : nil
  rescue Errno::ENOENT, Timeout::Error => e
    Rails.logger.warn "[WHATSAPP CALL] ffmpeg recording mix unavailable for #{session_id}: #{e.class} #{e.message}"
    nil
  ensure
    inputs&.each(&:close!)
    output&.close!
  end

  def recording_tempfiles(session_id, side_recordings)
    side_recordings.map do |recording|
      tempfile = Tempfile.new(["#{session_id}_#{recording[:side]}", '.ogg'])
      tempfile.binmode
      tempfile.write(recording[:data].dup.force_encoding('BINARY'))
      tempfile.flush
      tempfile
    end
  end

  def output_tempfile(session_id)
    Tempfile.new(["#{session_id}_mixed", '.ogg']).tap(&:binmode)
  end

  def run_ffmpeg_mix(session_id, inputs, output)
    _stdout, stderr, status = Timeout.timeout(MIX_TIMEOUT) { Open3.capture3(*ffmpeg_mix_args(inputs, output)) }
    return read_mixed_output(output) if status.success?

    Rails.logger.warn "[WHATSAPP CALL] ffmpeg recording mix failed for #{session_id}: #{stderr.to_s.truncate(500)}"
    nil
  end

  def ffmpeg_mix_args(inputs, output)
    ['ffmpeg', '-y', '-loglevel', 'error'] +
      inputs.flat_map { |file| ['-i', file.path] } +
      ['-filter_complex', '[0:a][1:a]amix=inputs=2:duration=longest:dropout_transition=0[aout]',
       '-map', '[aout]', '-c:a', 'libopus', '-b:a', '48000', '-ar', '48000', '-ac', '1', output.path]
  end

  def read_mixed_output(output)
    output.rewind
    output.read
  end

  def largest_recording(side_recordings)
    side_recordings.max_by { |recording| recording[:data].bytesize }[:data]
  end

  def attach_recording(call, recording_data)
    call.recording.attach(
      io: StringIO.new(recording_data.dup.force_encoding('BINARY')),
      filename: "call_#{call.id}_#{call.provider_call_id}.ogg",
      content_type: 'audio/ogg'
    )
  end
end
