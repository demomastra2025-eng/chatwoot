# frozen_string_literal: true

require 'openssl'

# Synchronizes and serves voice-recordings/* keys through the configured ActiveStorage S3 service
# (e.g. s3_compatible on ps.kz) while keeping local disk operations non-blocking on S3 errors.
module Storage::VoiceRecordingRemoteStorage
  PREFIX = 'voice-recordings/'
  URL_EXPIRES_IN = 15.minutes
  REMOTE_SERVICES = %w[s3_compatible amazon].freeze

  module_function

  def enabled?
    service_name = Rails.configuration.active_storage.service.to_s
    REMOTE_SERVICES.include?(service_name) && active_storage_service.present?
  rescue StandardError
    false
  end

  def upload_file(storage_key, local_path, content_type: nil)
    return false unless valid_key?(storage_key) && !raw_wav_key?(storage_key) && enabled?
    return false unless local_path.present? && File.file?(local_path)

    checksum = OpenSSL::Digest::MD5.file(local_path.to_s).base64digest
    File.open(local_path.to_s, 'rb') do |io|
      active_storage_service.upload(
        storage_key.to_s,
        io,
        checksum: checksum,
        content_type: content_type
      )
    end
    true
  rescue StandardError => e
    Rails.logger.warn("[VoiceRecordingRemoteStorage] Upload failed key=#{storage_key} error=#{e.class.name}: #{e.message}")
    false
  end

  def delete_key(storage_key)
    return false unless valid_key?(storage_key) && enabled?

    active_storage_service.delete(storage_key.to_s)
    true
  rescue StandardError => e
    Rails.logger.warn("[VoiceRecordingRemoteStorage] Delete failed key=#{storage_key} error=#{e.class.name}: #{e.message}")
    false
  end

  def url_for(storage_key, filename:, content_type:)
    return unless valid_key?(storage_key) && enabled?
    return unless active_storage_service.exist?(storage_key.to_s)

    active_storage_service.url(
      storage_key.to_s,
      expires_in: URL_EXPIRES_IN,
      filename: ActiveStorage::Filename.new(filename.presence || File.basename(storage_key.to_s)),
      content_type: content_type,
      disposition: :inline
    )
  rescue StandardError => e
    Rails.logger.warn("[VoiceRecordingRemoteStorage] URL generation failed key=#{storage_key} error=#{e.class.name}: #{e.message}")
    nil
  end

  def download(storage_key)
    return unless valid_key?(storage_key) && enabled?
    return unless active_storage_service.exist?(storage_key.to_s)

    active_storage_service.download(storage_key.to_s)
  rescue StandardError => e
    Rails.logger.warn("[VoiceRecordingRemoteStorage] Download failed key=#{storage_key} error=#{e.class.name}: #{e.message}")
    nil
  end

  def valid_key?(storage_key)
    key = storage_key.to_s
    key.start_with?(PREFIX) && key.exclude?('..')
  end

  def raw_wav_key?(storage_key)
    storage_key.to_s.downcase.end_with?('.wav')
  end

  def active_storage_service
    ActiveStorage::Blob.service if defined?(ActiveStorage::Blob)
  end
end
