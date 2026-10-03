# frozen_string_literal: true

require 'open3'
require 'fileutils'
require 'securerandom'

class Telephony::RecordingCompressionService
  CompressionError = Class.new(StandardError)
  DurationDriftError = Class.new(StandardError)

  TARGET_BITRATE = '48k'
  TARGET_SAMPLE_RATE = 32_000
  MAX_DURATION_DRIFT_SECONDS = 1.0
  TIMEOUT_SECONDS = 120

  def self.compress!(call_session: nil, storage_key: nil)
    new(call_session: call_session, storage_key: storage_key).perform!
  end

  def self.compress(call_session: nil, storage_key: nil)
    new(call_session: call_session, storage_key: storage_key).perform
  end

  def initialize(call_session: nil, storage_key: nil)
    @call_session = call_session
    @storage_key = storage_key || call_session&.recording_ref
  end

  def perform
    perform!
  rescue StandardError => e
    Rails.logger.warn("[RecordingCompressionService] Failed for #{@storage_key}: #{e.message}")
    { success: false, error: e.message }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def perform!
    return { skipped: true, reason: :blank_storage_key } if storage_key.blank?

    source_path = storage_root.join(storage_key).cleanpath
    return { skipped: true, reason: :file_not_found } unless File.file?(source_path)
    return { skipped: true, reason: :already_mp3 } if source_path.extname.casecmp?('.mp3')
    return { skipped: true, reason: :unsupported_ext } unless %w[.wav .wave .pcm].include?(source_path.extname.downcase)

    orig_size = File.size(source_path)
    orig_duration = probe_duration(source_path)

    temp_path = Pathname.new("#{source_path}.compressing_#{SecureRandom.hex(4)}.mp3")

    begin
      execute_ffmpeg!(source_path, temp_path)

      validate_output_file!(temp_path)
      comp_duration = probe_duration(temp_path)
      validate_duration_drift!(orig_duration, comp_duration)

      comp_size = File.size(temp_path)
      target_path = source_path.sub_ext('.mp3')
      target_storage_key = storage_key.sub(/\.(wav|wave|pcm)\z/i, '.mp3')

      FileUtils.mv(temp_path, target_path)
      FileUtils.rm_f(source_path)

      update_database_records!(target_storage_key, comp_size, comp_duration)

      {
        success: true,
        original_bytes: orig_size,
        compressed_bytes: comp_size,
        freed_bytes: [orig_size - comp_size, 0].max,
        original_storage_key: storage_key,
        new_storage_key: target_storage_key,
        duration: comp_duration
      }
    ensure
      FileUtils.rm_f(temp_path)
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  private

  attr_reader :storage_key, :call_session

  def storage_root
    @storage_root ||= Rails.root.join('storage')
  end

  def execute_ffmpeg!(source_path, temp_path)
    cmd = [
      'ffmpeg', '-y',
      '-i', source_path.to_s,
      '-vn',
      '-ac', '1',
      '-ar', TARGET_SAMPLE_RATE.to_s,
      '-b:a', TARGET_BITRATE,
      temp_path.to_s
    ]

    _stdout, stderr, status = Open3.capture3(*cmd)
    return if status.success?

    raise CompressionError, "ffmpeg exited with #{status.exitstatus}: #{stderr.lines.last(3).join(' ').strip}"
  end

  def validate_output_file!(temp_path)
    raise CompressionError, 'Output compressed file does not exist' unless File.file?(temp_path)
    raise CompressionError, 'Output compressed file is empty' if File.empty?(temp_path)
  end

  def validate_duration_drift!(orig_dur, comp_dur)
    return unless orig_dur.positive? && comp_dur.positive?

    drift = (comp_dur - orig_dur).abs
    return if drift <= MAX_DURATION_DRIFT_SECONDS

    raise DurationDriftError, "Duration drift #{drift.round(3)}s exceeds #{MAX_DURATION_DRIFT_SECONDS}s"
  end

  def probe_duration(file_path)
    cmd = [
      'ffprobe', '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      file_path.to_s
    ]

    stdout, _stderr, status = Open3.capture3(*cmd)
    return 0.0 unless status.success?

    Float(stdout.strip)
  rescue StandardError
    0.0
  end

  def update_database_records!(target_storage_key, comp_size, comp_duration)
    session = call_session || find_call_session
    return unless session

    ActiveRecord::Base.transaction do
      update_call_session!(session, target_storage_key, comp_size, comp_duration)
      update_messages!(session, target_storage_key, comp_size)
      update_conversation!(session, target_storage_key)
    end

    session.account&.storage_breakdown(force_refresh: true)
  rescue StandardError => e
    Rails.logger.warn("[RecordingCompressionService#update_database_records] #{e.message}")
  end

  def find_call_session
    return unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    Telephony::CallSession.find_by(recording_ref: storage_key)
  end

  def update_call_session!(session, target_key, comp_size, comp_duration)
    session.recording_ref = target_key
    meta = session.metadata.is_a?(Hash) ? session.metadata.deep_dup : {}
    rec_meta = meta['recording'].is_a?(Hash) ? meta['recording'] : {}
    rec_meta['storage_key'] = target_key
    rec_meta['byte_size'] = comp_size
    rec_meta['compressed'] = true
    rec_meta['codec'] = 'mp3_48k'
    rec_meta['duration_seconds'] = comp_duration.round if comp_duration.positive?
    meta['recording'] = rec_meta
    session.metadata = meta
    session.duration_seconds ||= comp_duration.round if comp_duration.positive?
    session.save!
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
  def update_messages!(session, target_key, comp_size)
    return if session.conversation_id.blank?

    new_playback_url = begin
      Telephony::CallRecordingPlaybackUrl.path_for(session, storage_key: target_key)
    rescue StandardError
      nil
    end

    Message.where(conversation_id: session.conversation_id).find_each do |msg|
      data = msg.content_attributes&.dig('data')
      next unless data.is_a?(Hash)

      changed = false
      if data.dig('recording', 'storage_key') == storage_key
        data['recording']['storage_key'] = target_key
        data['recording']['byte_size'] = comp_size
        changed = true
      end

      if data['recording_ref'] == storage_key
        data['recording_ref'] = target_key
        changed = true
      end

      if changed
        data['recording_url'] = new_playback_url if new_playback_url
        msg.content_attributes['data'] = data
        msg.save!
      end
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength

  def update_conversation!(session, target_key)
    conv = session.conversation
    return unless conv&.additional_attributes.is_a?(Hash)

    rec_data = conv.additional_attributes['recording']
    return unless rec_data.is_a?(Hash) && rec_data['storage_key'] == storage_key

    rec_data['storage_key'] = target_key
    conv.additional_attributes['recording'] = rec_data
    conv.save!
  end
end
