# frozen_string_literal: true

class Accounts::HeavyFilesService
  InvalidParams = Class.new(ArgumentError)
  AttachmentTimeout = Class.new(StandardError)

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
    @inbox_id = integer_filter(params[:inbox_id])
    @conversation_id = integer_filter(params[:conversation_id])
    @date_from = parse_date(params[:date_from], :date_from)
    @date_to = parse_date(params[:date_to], :date_to)
    @limit = (params[:limit] || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
    validate_date_range!
  end

  def perform
    items = []
    items.concat(fetch_attachments) if fetch_attachments?
    items.concat(fetch_recordings) if fetch_recordings?

    items.sort_by { |item| -item[:byte_size] }.first(@limit)
  end

  def recordings_pending?
    @recordings_pending == true
  end

  private

  attr_reader :account, :file_type, :inbox_id, :conversation_id, :date_from, :date_to, :limit

  def integer_filter(value)
    value.presence&.to_i
  end

  def validate_date_range!
    raise InvalidParams, I18n.t('storage_management.errors.invalid_date_range') if date_from && date_to && date_from > date_to
  end

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
    scope = filtered_attachment_scope
    raw_data, inbox_names, blobs = with_statement_timeout do
      rows = scope.order('active_storage_blobs.byte_size DESC')
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
      [rows, account.inboxes.pluck(:id, :name).to_h, ActiveStorage::Blob.where(id: rows.map(&:last)).index_by(&:id)]
    end

    raw_data.map { |row| format_attachment_row(row, inbox_names, blobs[row.last]) }
  rescue StandardError => e
    raise AttachmentTimeout, I18n.t('storage_management.errors.heavy_files_timeout') if query_timeout?(e)

    Rails.logger.warn("[HeavyFilesService#fetch_attachments] Failed for account #{account.id}: #{e.class.name}")
    []
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def filtered_attachment_scope
    scope = base_attachment_scope
    scope = scope.where(messages: { inbox_id: inbox_id }) if inbox_id.present?
    scope = scope.where(messages: { conversation_id: conversation_id }) if conversation_id.present?
    scope = scope.where('attachments.created_at >= ?', date_from.beginning_of_day) if date_from
    scope = scope.where('attachments.created_at <= ?', date_to.end_of_day) if date_to

    return scope unless FILE_TYPE_MAPPINGS.key?(file_type)

    enum_val = Attachment.file_types[FILE_TYPE_MAPPINGS[file_type]]
    enum_val ? scope.where(attachments: { file_type: enum_val }) : scope
  end

  def base_attachment_scope
    join_sql = 'INNER JOIN attachments ON attachments.id = active_storage_attachments.record_id ' \
               "AND active_storage_attachments.record_type = 'Attachment'"
    ActiveStorage::Attachment.joins(:blob)
                             .joins(join_sql)
                             .joins('INNER JOIN messages ON messages.id = attachments.message_id')
                             .where(attachments: { account_id: account.id })
                             .where(messages: { account_id: account.id })
                             .where("(attachments.meta->'trash') IS NULL")
  end

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

  def fetch_recordings
    snapshot = Accounts::HeavyRecordingsSnapshot.new(account_id: account.id).snapshot
    unless snapshot
      @recordings_pending = true
      return []
    end

    rows = snapshot.fetch(:recordings).select { |row| recording_matches?(row) }
    return [] if rows.empty?

    inbox_names = account.inboxes.pluck(:id, :name).to_h
    rows.map { |row| format_recording_row(row, inbox_names) }
  rescue StandardError => e
    Rails.logger.warn("[HeavyFilesService#fetch_recordings] Failed for account #{account.id}: #{e.class.name}")
    @recordings_pending = true
    []
  end

  def recording_matches?(row)
    return false unless (!inbox_id || row[:inbox_id] == inbox_id) && (!conversation_id || row[:conversation_id] == conversation_id)

    recording_date_matches?(row[:created_at])
  end

  def recording_date_matches?(date)
    return true unless date_from || date_to

    created_at = Time.zone.parse(date.to_s)
    created_at && after_start?(created_at) && before_end?(created_at)
  end

  def after_start?(created_at)
    date_from.nil? || created_at >= date_from.beginning_of_day
  end

  def before_end?(created_at)
    date_to.nil? || created_at <= date_to.end_of_day
  end

  def format_recording_row(row, inbox_names)
    row.merge(
      name: I18n.t('storage_management.item_labels.audio_recording'),
      file_type: 'recording',
      human_size: ActiveSupport::NumberHelper.number_to_human_size(row[:byte_size]),
      inbox_name: inbox_names[row[:inbox_id]] || I18n.t('storage_management.unknown_channel')
    )
  end

  def query_timeout?(error)
    error.is_a?(ActiveRecord::QueryCanceled) || error.cause&.class&.name == 'PG::QueryCanceled'
  end

  def with_statement_timeout
    connection = ActiveRecord::Base.connection
    previous_timeout = connection.select_value('SHOW statement_timeout')
    connection.execute("SET statement_timeout = '10s'")
    yield
  ensure
    restore_statement_timeout(connection, previous_timeout)
  end

  def restore_statement_timeout(connection, previous_timeout)
    return if connection.nil? || previous_timeout.nil?

    connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT set_config(?, ?, false)', 'statement_timeout', previous_timeout]))
  rescue StandardError => e
    Rails.logger.warn("[HeavyFilesService] Could not restore statement_timeout: #{e.class.name}")
  end
end
