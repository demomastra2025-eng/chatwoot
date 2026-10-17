# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Telephony
  module Beeline
    class RecordingSyncService
      def initialize(call_session:, record_id:, api_client: nil)
        @call_session = call_session
        @record_id = record_id.to_s.strip
        @api_client = api_client || build_default_client
      end

      def perform
        return false if @call_session.blank? || @record_id.blank?
        return false if @api_client.blank? || !@api_client.configured?
        return false if recording_already_persisted?

        downloaded = @api_client.download_recording(@record_id)
        raw_audio = downloaded[:body].to_s
        return false if raw_audio.blank?

        content_type = downloaded[:content_type].presence || 'audio/mpeg'
        sha256 = Digest::SHA256.hexdigest(raw_audio)
        ext = extension_for_content_type(content_type)
        storage_key = beeline_recording_storage_key(@call_session.external_call_ref, sha256, ext)
        persist_recording_file!(storage_key, raw_audio, sha256)

        ready_payload = {
          'event' => 'recording_ready',
          'event_key' => "beeline:recording:#{@call_session.account_id}:#{@call_session.external_call_ref}:#{@record_id}",
          'call_ref' => @call_session.external_call_ref,
          'account_id' => @call_session.account_id,
          'inbox_id' => @call_session.inbox_id,
          'number_ref' => @call_session.number_binding&.number_ref,
          'provider' => 'beeline',
          'recording_ref' => storage_key,
          'storage_key' => storage_key,
          'byte_size' => raw_audio.bytesize,
          'content_type' => content_type,
          'sha256' => sha256,
          'metadata' => {
            'recording_import' => {
              'source' => 'beeline_cdr_media',
              'beeline_record_id' => @record_id,
              'storage_key' => storage_key,
              'sha256' => sha256
            }
          }
        }

        updated_session = Telephony::EventsIngestionService.new(payload: ready_payload).perform || @call_session.reload
        Telephony::VoiceMessageRecordingSyncService.new(call_session: updated_session).perform
        Telephony::CompressRecordingsJob.perform_later(call_session_id: updated_session.id)
        true
      rescue StandardError => e
        Rails.logger.warn(
          "TELEPHONY_BEELINE_RECORDING_SYNC_FAILED call_session_id=#{@call_session&.id} " \
          "record_id=#{@record_id} error=#{e.class.name}: #{e.message}"
        )
        false
      end

      alias call perform

      private

      def build_default_client
        channel = @call_session&.inbox&.channel
        return nil unless channel.is_a?(Channel::Voice)

        ApiClient.for_channel(channel)
      end

      def recording_already_persisted?
        ref = @call_session.recording_ref.to_s
        return false if ref.blank?

        ref.start_with?('voice-recordings/') ||
          @call_session.metadata.to_h.dig('recording', 'storage_key').present?
      end

      def extension_for_content_type(content_type)
        case content_type.to_s.downcase
        when /wav/ then 'wav'
        when /ogg/ then 'ogg'
        else 'mp3'
        end
      end

      def beeline_recording_storage_key(call_ref, sha256, ext)
        safe_ref = call_ref.to_s.gsub(/[^a-zA-Z0-9._-]/, '_')
        "voice-recordings/beeline/#{@call_session.account_id}/#{safe_ref}/#{sha256}.#{ext}"
      end

      def persist_recording_file!(storage_key, raw_audio, sha256)
        storage_root = Rails.root.join('storage').cleanpath
        path = storage_root.join(storage_key).cleanpath
        raise 'Invalid Beeline recording storage path' unless path.to_s.start_with?("#{storage_root}/")
        return if File.file?(path) && Digest::SHA256.file(path).hexdigest.casecmp?(sha256)

        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, raw_audio)
      end
    end
  end
end
