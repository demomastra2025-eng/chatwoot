# frozen_string_literal: true

class Accounts::HeavyFilesService
  InvalidParams = Class.new(ArgumentError)

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
    @conversation_id = params[:conversation_id].presence&.to_i
    @date_from = parse_date(params[:date_from], :date_from)
    @date_to = parse_date(params[:date_to], :date_to)
    raise InvalidParams, I18n.t('storage_management.errors.invalid_date_range') if @date_from && @date_to && @date_from > @date_to

    @limit = (params[:limit] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
  end

  def perform
    items = []
    items.concat(fetch_attachments) if fetch_attachments?
    items.concat(fetch_recordings) if fetch_recordings?

    items.sort_by { |item| -item[:byte_size] }.first(@limit)
  end

  private

  attr_reader :account, :file_type, :inbox_id, :conversation_id, :date_from, :date_to, :limit

  def fetch_attachments?
    file_type == 'all' || FILE_TYPE_MAPPINGS.key?(file_type)
  end

  def fetch_recordings?
    file_type == 'all' || file_type == 'recordings'
  end

  def parse_date(value, name)
    return if value.blank?

    Date.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    raise InvalidParams, I18n.t('storage_management.errors.invalid_date', field: name)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def fetch_attachments
    join_sql = 'INNER JOIN attachments ON attachments.id = active_storage_attachments.record_id ' \
               "AND active_storage_attachments.record_type = 'Attachment'"
    scope = ActiveStorage::Attachment.joins(:blob)
                                     .joins(join_sql)
                                     .joins('INNER JOIN messages ON messages.id = attachments.message_id')
                                     .where(attachments: { account_id: account.id })
                                     .where(messages: { account_id: account.id })
                                     .where("(attachments.meta->'trash') IS NULL")

    scope = scope.where(messages: { inbox_id: inbox_id }) if inbox_id.present?
    scope = scope.where(messages: { conversation_id: conversation_id }) if conversation_id.present?
    scope = scope.where('attachments.created_at >= ?', date_from.beginning_of_day) if date_from
    scope = scope.where('attachments.created_at <= ?', date_to.end_of_day) if date_to

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
                      'active_storage_attachments.blob_id'
                    )

    inbox_names = account.inboxes.pluck(:id, :name).to_h
    blobs = ActiveStorage::Blob.where(id: raw_data.map(&:last)).index_by(&:id)

    raw_data.map do |row|
      format_attachment_row(row, inbox_names, blobs[row.last])
    end
  rescue StandardError => e
    Rails.logger.warn("[HeavyFilesService#fetch_attachments] Failed: #{e.message}")
    []
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def format_attachment_row(row, inbox_names, blob)
    att_id, _filename, byte_size, ft_int, created_at, in_id, conv_id, = row

    {
      id: "attachment_#{att_id}",
      name: I18n.t('storage_management.item_labels.file'),
      file_type: UI_TYPE_MAP.fetch(Attachment.file_types.key(ft_int), 'document'),
      byte_size: byte_size.to_i,
      human_size: ActiveSupport::NumberHelper.number_to_human_size(byte_size.to_i),
      created_at: created_at&.iso8601,
      inbox_id: in_id,
      inbox_name: inbox_names[in_id] || I18n.t('storage_management.unknown_channel'),
      conversation_id: conv_id,
      download_url: blob_download_path(blob)
    }
  end

  # ActiveStorage only serves blobs through their *signed* id; a raw database id always ends in a 404.
  def blob_download_path(blob)
    return if blob.blank?

    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true, disposition: 'attachment')
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
  def fetch_recordings
    return [] unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    scope = Telephony::CallSession.where(account_id: account.id)
                                  .where.not(recording_ref: [nil, ''])

    scope = scope.where(inbox_id: inbox_id) if inbox_id.present?
    scope = scope.where(conversation_id: conversation_id) if conversation_id.present?
    scope = scope.where('created_at >= ?', date_from.beginning_of_day) if date_from
    scope = scope.where('created_at <= ?', date_to.end_of_day) if date_to

    inbox_names = account.inboxes.pluck(:id, :name).to_h

    recordings = []
    scope.find_each do |session|
      ref = session.recording_ref
      next if ref.blank?

      file_path = Storage::RecordingPaths.resolve(ref, account_id: account.id)
      # Count physical files only. A provider URL or stale metadata byte_size is not local disk usage.
      next unless file_path

      file_size = File.size(file_path)
      next if file_size.zero?

      download_url = begin
        Telephony::CallRecordingPlaybackUrl.path_for(session, storage_key: ref)
      rescue StandardError
        nil
      end

      label = I18n.t('storage_management.item_labels.audio_recording')

      recordings << {
        id: "call_#{session.id}",
        name: label,
        file_type: 'recording',
        byte_size: file_size,
        human_size: ActiveSupport::NumberHelper.number_to_human_size(file_size),
        created_at: session.created_at&.iso8601,
        inbox_id: session.inbox_id,
        inbox_name: inbox_names[session.inbox_id] || I18n.t('storage_management.unknown_channel'),
        conversation_id: session.conversation_id,
        download_url: download_url
      }
    end

    recordings
  rescue StandardError => e
    Rails.logger.warn("[HeavyFilesService#fetch_recordings] Failed: #{e.message}")
    []
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
end
