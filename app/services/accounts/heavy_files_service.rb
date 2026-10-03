# frozen_string_literal: true

class Accounts::HeavyFilesService
  DEFAULT_LIMIT = 50
  MAX_LIMIT = 100

  FILE_TYPE_MAPPINGS = {
    'images' => 'image',
    'audio' => 'audio',
    'videos' => 'video',
    'documents' => 'file'
  }.freeze

  UI_TYPE_MAP = {
    'image' => 'image',
    'audio' => 'audio',
    'video' => 'video'
  }.freeze

  def initialize(account:, params: {})
    @account = account
    @file_type = params[:file_type].to_s.presence || 'all'
    @inbox_id = params[:inbox_id].presence&.to_i
    @limit = (params[:limit] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
  end

  def perform
    items = []
    items.concat(fetch_attachments) if fetch_attachments?
    items.concat(fetch_recordings) if fetch_recordings?

    items.sort_by { |item| -item[:byte_size] }.first(@limit)
  end

  private

  attr_reader :account, :file_type, :inbox_id, :limit

  def fetch_attachments?
    file_type == 'all' || FILE_TYPE_MAPPINGS.key?(file_type)
  end

  def fetch_recordings?
    file_type == 'all' || file_type == 'recordings'
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def fetch_attachments
    join_sql = 'INNER JOIN attachments ON attachments.id = active_storage_attachments.record_id ' \
               "AND active_storage_attachments.record_type = 'Attachment'"
    scope = ActiveStorage::Attachment.joins(:blob)
                                     .joins(join_sql)
                                     .joins('INNER JOIN messages ON messages.id = attachments.message_id')
                                     .where(attachments: { account_id: account.id })

    scope = scope.where(messages: { inbox_id: inbox_id }) if inbox_id.present?

    if FILE_TYPE_MAPPINGS.key?(file_type)
      target_type = FILE_TYPE_MAPPINGS[file_type]
      enum_val = Attachment.file_types[target_type]
      scope = scope.where(attachments: { file_type: enum_val }) if enum_val
    end

    raw_data = scope.order('active_storage_blobs.byte_size DESC')
                    .limit(limit)
                    .pluck(
                      'attachments.id',
                      'active_storage_blobs.filename',
                      'active_storage_blobs.byte_size',
                      'attachments.file_type',
                      'attachments.created_at',
                      'messages.inbox_id',
                      'messages.conversation_id',
                      'active_storage_attachments.id'
                    )

    inbox_names = account.inboxes.pluck(:id, :name).to_h

    raw_data.map do |row|
      format_attachment_row(row, inbox_names)
    end
  rescue StandardError => e
    Rails.logger.warn("[HeavyFilesService#fetch_attachments] Failed: #{e.message}")
    []
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def format_attachment_row(row, inbox_names)
    att_id, filename, byte_size, ft_int, created_at, in_id, conv_id, as_id = row
    encoded_filename = URI.encode_uri_component(filename.to_s)

    {
      id: "attachment_#{att_id}",
      name: filename.to_s.presence || "Файл ##{att_id}",
      file_type: UI_TYPE_MAP.fetch(Attachment.file_types.key(ft_int), 'document'),
      byte_size: byte_size.to_i,
      human_size: ActiveSupport::NumberHelper.number_to_human_size(byte_size.to_i),
      created_at: created_at&.iso8601,
      inbox_id: in_id,
      inbox_name: inbox_names[in_id] || "Канал ##{in_id}",
      conversation_id: conv_id,
      download_url: "/rails/active_storage/blobs/redirect/#{as_id}/#{encoded_filename}"
    }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/BlockLength
  def fetch_recordings
    return [] unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    scope = Telephony::CallSession.where(account_id: account.id)
                                  .where.not(recording_ref: [nil, ''])

    scope = scope.where(inbox_id: inbox_id) if inbox_id.present?

    candidate_sessions = scope.order(Arel.sql('COALESCE(duration_seconds, 0) DESC, created_at DESC'))
                              .limit(limit * 2)

    inbox_names = account.inboxes.pluck(:id, :name).to_h
    storage_root = Rails.root.join('storage')

    recordings = []
    candidate_sessions.each do |session|
      ref = session.recording_ref
      next if ref.blank?

      file_path = storage_root.join(ref)
      file_size = if File.file?(file_path)
                    File.size(file_path)
                  elsif session.metadata.is_a?(Hash) && session.metadata.dig('recording', 'byte_size').to_i.positive?
                    session.metadata['recording']['byte_size'].to_i
                  else
                    0
                  end

      next if file_size.zero?

      download_url = begin
        Telephony::CallRecordingPlaybackUrl.path_for(session, storage_key: ref)
      rescue StandardError
        nil
      end

      label = if session.from_number.present? && session.to_number.present?
                "Звонок #{session.from_number} -> #{session.to_number}"
              else
                File.basename(ref)
              end

      recordings << {
        id: "call_#{session.id}",
        name: label,
        file_type: 'recording',
        byte_size: file_size,
        human_size: ActiveSupport::NumberHelper.number_to_human_size(file_size),
        created_at: session.created_at&.iso8601,
        inbox_id: session.inbox_id,
        inbox_name: inbox_names[session.inbox_id] || "Канал ##{session.inbox_id}",
        conversation_id: session.conversation_id,
        download_url: download_url
      }
    end

    recordings
  rescue StandardError => e
    Rails.logger.warn("[HeavyFilesService#fetch_recordings] Failed: #{e.message}")
    []
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/BlockLength
end
