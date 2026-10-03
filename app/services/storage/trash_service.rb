# frozen_string_literal: true

require 'fileutils'

# rubocop:disable Metrics/ClassLength
class Storage::TrashService
  RETENTION_DAYS = 30

  def initialize(account:)
    @account = account
  end

  def preview(file_type: 'all', older_than_months: 6, inbox_id: nil)
    cutoff_date = cutoff_timestamp(older_than_months)
    recordings_res = preview_recordings(cutoff_date, inbox_id, file_type)
    attachments_res = preview_attachments(cutoff_date, inbox_id, file_type)

    total_count = recordings_res[:count] + attachments_res[:count]
    total_bytes = recordings_res[:bytes] + attachments_res[:bytes]
    samples = (recordings_res[:samples] + attachments_res[:samples]).sort_by { |s| -s[:byte_size] }.first(20)

    {
      total_count: total_count,
      total_bytes: total_bytes,
      recordings_count: recordings_res[:count],
      recordings_bytes: recordings_res[:bytes],
      attachments_count: attachments_res[:count],
      attachments_bytes: attachments_res[:bytes],
      retention_days: RETENTION_DAYS,
      samples: samples
    }
  end

  def move_to_trash!(file_type: 'all', older_than_months: 6, inbox_id: nil)
    cutoff_date = cutoff_timestamp(older_than_months)
    expires_at = RETENTION_DAYS.days.from_now

    moved_recordings = move_recordings_to_trash(cutoff_date, inbox_id, file_type, expires_at)
    moved_attachments = move_attachments_to_trash(cutoff_date, inbox_id, file_type, expires_at)

    total_count = moved_recordings[:count] + moved_attachments[:count]
    total_bytes = moved_recordings[:bytes] + moved_attachments[:bytes]

    @account.storage_breakdown(force_refresh: true) if @account.respond_to?(:storage_breakdown)

    {
      success: true,
      moved_count: total_count,
      freed_bytes: total_bytes,
      retention_days: RETENTION_DAYS,
      expires_at: expires_at.iso8601
    }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def list_trash(page: 1, limit: 50)
    limit = limit.to_i.clamp(1, 100)
    page = page.to_i.clamp(1, 10_000)
    offset = (page - 1) * limit

    items = []
    total_bytes = 0

    # 1. Trashed recordings
    if defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?
      trashed_sessions = Telephony::CallSession.where(account_id: @account.id)
                                               .where("metadata->'trash' IS NOT NULL")
                                               .includes(:inbox)
      trashed_sessions.find_each do |session|
        trash_meta = session.metadata['trash'] || {}
        bytes = trash_meta['bytes'].to_i
        total_bytes += bytes
        items << format_trash_session(session, trash_meta, bytes)
      end
    end

    # 2. Trashed attachments
    trashed_attachments = Attachment.where(account_id: @account.id)
                                    .where("meta->'trash' IS NOT NULL")
                                    .includes(:message, file_attachment: :blob)
    trashed_attachments.find_each do |attachment|
      trash_meta = attachment.meta['trash'] || {}
      bytes = trash_meta['bytes'].to_i
      total_bytes += bytes
      items << format_trash_attachment(attachment, trash_meta, bytes)
    end

    sorted_items = items.sort_by { |item| item[:deleted_at] || '' }.reverse
    total_count = sorted_items.size
    paged_items = sorted_items.slice(offset, limit) || []

    {
      total_count: total_count,
      total_bytes: total_bytes,
      page: page,
      limit: limit,
      items: paged_items
    }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/PerceivedComplexity
  def restore!(item_type: nil, item_id: nil, restore_all: false)
    restored_count = 0
    restored_bytes = 0

    if restore_all
      recordings_res = restore_all_recordings
      attachments_res = restore_all_attachments
      restored_count = recordings_res[:count] + attachments_res[:count]
      restored_bytes = recordings_res[:bytes] + attachments_res[:bytes]
    elsif item_type.to_s == 'recording' && item_id.present?
      res = restore_single_recording(item_id)
      restored_count = res[:count]
      restored_bytes = res[:bytes]
    elsif item_type.to_s == 'attachment' && item_id.present?
      res = restore_single_attachment(item_id)
      restored_count = res[:count]
      restored_bytes = res[:bytes]
    end

    @account.storage_breakdown(force_refresh: true) if @account.respond_to?(:storage_breakdown)

    {
      success: true,
      restored_count: restored_count,
      restored_bytes: restored_bytes
    }
  end

  def empty_trash!(item_type: nil, item_id: nil, purge_all: false)
    purged_count = 0
    purged_bytes = 0

    if purge_all || (item_type.blank? && item_id.blank?)
      recordings_res = purge_all_recordings
      attachments_res = purge_all_attachments
      purged_count = recordings_res[:count] + attachments_res[:count]
      purged_bytes = recordings_res[:bytes] + attachments_res[:bytes]
      cleanup_trash_directory
    elsif item_type.to_s == 'recording' && item_id.present?
      res = purge_single_recording(item_id)
      purged_count = res[:count]
      purged_bytes = res[:bytes]
    elsif item_type.to_s == 'attachment' && item_id.present?
      res = purge_single_attachment(item_id)
      purged_count = res[:count]
      purged_bytes = res[:bytes]
    end

    @account.storage_breakdown(force_refresh: true) if @account.respond_to?(:storage_breakdown)

    {
      success: true,
      purged_count: purged_count,
      purged_bytes: purged_bytes
    }
  end

  def self.purge_expired_all!
    purged_count = 0
    purged_bytes = 0
    now_iso = Time.current.iso8601

    if defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?
      Telephony::CallSession.where("(metadata->'trash'->>'expires_at') <= ?", now_iso).find_each do |session|
        trash_meta = session.metadata['trash'] || {}
        trash_path = trash_meta['trash_path']
        bytes = trash_meta['bytes'].to_i

        File.delete(trash_path) if trash_path.present? && File.exist?(trash_path)
        session.metadata.delete('trash')
        session.metadata['recording'] ||= {}
        session.metadata['recording']['purged'] = true
        session.metadata['recording']['purged_at'] = Time.current.iso8601
        session.recording_ref = nil
        session.save(validate: false)

        purged_count += 1
        purged_bytes += bytes
      end
    end

    Attachment.where("(meta->'trash'->>'expires_at') <= ?", now_iso).find_each do |attachment|
      bytes = attachment.file.attached? ? attachment.file.byte_size.to_i : 0
      attachment.file.purge if attachment.file.attached?
      attachment.destroy

      purged_count += 1
      purged_bytes += bytes
    end

    Rails.logger.info("[Storage::TrashService] Purged expired trash: #{purged_count} files, #{purged_bytes} bytes")
    { purged_count: purged_count, purged_bytes: purged_bytes }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  private

  def human_size(bytes)
    ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i)
  end

  def cutoff_timestamp(months)
    return nil if months.to_i <= 0

    months.to_i.months.ago
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def preview_recordings(cutoff_date, inbox_id, file_type)
    return { count: 0, bytes: 0, samples: [] } if %w[image video file].include?(file_type)
    return { count: 0, bytes: 0, samples: [] } unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    scope = Telephony::CallSession.where(account_id: @account.id)
                                  .where.not(recording_ref: [nil, ''])
                                  .where("(metadata->'trash') IS NULL")
    scope = scope.where('created_at < ?', cutoff_date) if cutoff_date.present?
    scope = scope.where(inbox_id: inbox_id) if inbox_id.present?

    total_bytes = 0
    samples = []

    scope.includes(:inbox).find_each do |session|
      path = resolve_recording_path(session)
      size = path && File.exist?(path) ? File.size(path) : 0
      total_bytes += size

      if samples.size < 10
        samples << {
          id: session.id,
          item_type: 'recording',
          file_name: File.basename(session.recording_ref.to_s),
          file_type: 'audio',
          byte_size: size,
          created_at: session.created_at.iso8601,
          inbox_id: session.inbox_id,
          inbox_name: session.inbox&.name
        }
      end
    end

    { count: scope.count, bytes: total_bytes, samples: samples }
  end

  def preview_attachments(cutoff_date, inbox_id, file_type)
    return { count: 0, bytes: 0, samples: [] } if file_type == 'recordings'

    scope = Attachment.joins(:file_blob)
                      .where(account_id: @account.id)
                      .where("(attachments.meta->'trash') IS NULL")
    scope = scope.where('attachments.created_at < ?', cutoff_date) if cutoff_date.present?
    scope = scope.joins(:message).where(messages: { inbox_id: inbox_id }) if inbox_id.present?
    scope = scope.where(file_type: file_type) if file_type.present? && %w[all attachments].exclude?(file_type)

    count = scope.count
    bytes = scope.sum('active_storage_blobs.byte_size').to_i

    samples = scope.includes(:message, file_attachment: :blob).order('active_storage_blobs.byte_size DESC').limit(10).map do |att|
      blob = att.file.blob
      {
        id: att.id,
        item_type: 'attachment',
        file_name: blob.filename.to_s,
        file_type: att.file_type,
        byte_size: blob.byte_size.to_i,
        created_at: att.created_at.iso8601,
        inbox_id: att.message&.inbox_id,
        inbox_name: att.message&.inbox&.name
      }
    end

    { count: count, bytes: bytes, samples: samples }
  end

  def move_recordings_to_trash(cutoff_date, inbox_id, file_type, expires_at)
    return { count: 0, bytes: 0 } if %w[image video file].include?(file_type)
    return { count: 0, bytes: 0 } unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    scope = Telephony::CallSession.where(account_id: @account.id)
                                  .where.not(recording_ref: [nil, ''])
                                  .where("(metadata->'trash') IS NULL")
    scope = scope.where('created_at < ?', cutoff_date) if cutoff_date.present?
    scope = scope.where(inbox_id: inbox_id) if inbox_id.present?

    trash_dir = Rails.root.join('storage', 'trash', @account.id.to_s, 'recordings')
    FileUtils.mkdir_p(trash_dir)

    count = 0
    bytes = 0

    scope.find_each do |session|
      path = resolve_recording_path(session)
      file_size = path && File.exist?(path) ? File.size(path) : 0
      trash_file_path = nil

      if path && File.exist?(path)
        trash_file_name = "#{session.id}_#{File.basename(path)}"
        trash_file_path = trash_dir.join(trash_file_name).to_s
        FileUtils.mv(path.to_s, trash_file_path)
        bytes += file_size
      end

      session.metadata ||= {}
      session.metadata['trash'] = {
        'deleted_at' => Time.current.iso8601,
        'expires_at' => expires_at.iso8601,
        'original_recording_ref' => session.recording_ref,
        'original_path' => path&.to_s,
        'trash_path' => trash_file_path,
        'bytes' => file_size
      }
      session.recording_ref = nil
      session.save(validate: false)
      count += 1
    end

    { count: count, bytes: bytes }
  end

  def move_attachments_to_trash(cutoff_date, inbox_id, file_type, expires_at)
    return { count: 0, bytes: 0 } if file_type == 'recordings'

    scope = Attachment.joins(:file_blob)
                      .where(account_id: @account.id)
                      .where("(attachments.meta->'trash') IS NULL")
    scope = scope.where('attachments.created_at < ?', cutoff_date) if cutoff_date.present?
    scope = scope.joins(:message).where(messages: { inbox_id: inbox_id }) if inbox_id.present?
    scope = scope.where(file_type: file_type) if file_type.present? && %w[all attachments].exclude?(file_type)

    count = 0
    bytes = 0

    scope.includes(file_attachment: :blob).find_each do |attachment|
      size = attachment.file.attached? ? attachment.file.byte_size.to_i : 0
      attachment.meta ||= {}
      attachment.meta['trash'] = {
        'deleted_at' => Time.current.iso8601,
        'expires_at' => expires_at.iso8601,
        'bytes' => size
      }
      attachment.save(validate: false)
      bytes += size
      count += 1
    end

    { count: count, bytes: bytes }
  end

  def format_trash_session(session, trash_meta, bytes)
    expires_at = trash_meta['expires_at']
    days_remaining = calculate_days_remaining(expires_at)

    {
      id: session.id,
      item_type: 'recording',
      file_name: File.basename(trash_meta['original_recording_ref'] || session.recording_ref || "call_#{session.id}"),
      file_type: 'audio',
      byte_size: bytes,
      deleted_at: trash_meta['deleted_at'],
      expires_at: expires_at,
      days_remaining: days_remaining,
      inbox_id: session.inbox_id,
      inbox_name: session.inbox&.name
    }
  end

  def format_trash_attachment(attachment, trash_meta, bytes)
    expires_at = trash_meta['expires_at']
    days_remaining = calculate_days_remaining(expires_at)
    blob = attachment.file.attached? ? attachment.file.blob : nil

    {
      id: attachment.id,
      item_type: 'attachment',
      file_name: blob&.filename&.to_s || "file_#{attachment.id}",
      file_type: attachment.file_type,
      byte_size: bytes,
      deleted_at: trash_meta['deleted_at'],
      expires_at: expires_at,
      days_remaining: days_remaining,
      inbox_id: attachment.message&.inbox_id,
      inbox_name: attachment.message&.inbox&.name
    }
  end

  def calculate_days_remaining(expires_at_str)
    return 0 if expires_at_str.blank?

    begin
      expires_time = Time.zone.parse(expires_at_str)
    rescue StandardError
      expires_time = nil
    end
    return 0 unless expires_time

    [((expires_time - Time.current) / 1.day).ceil, 0].max
  end

  def restore_single_recording(session_id)
    session = Telephony::CallSession.find_by(id: session_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless session&.metadata&.dig('trash')

    trash_meta = session.metadata['trash']
    trash_path = trash_meta['trash_path']
    orig_path = trash_meta['original_path']

    if trash_path.present? && File.exist?(trash_path) && orig_path.present?
      FileUtils.mkdir_p(File.dirname(orig_path))
      FileUtils.mv(trash_path, orig_path)
    end

    session.recording_ref = trash_meta['original_recording_ref']
    bytes = trash_meta['bytes'].to_i
    session.metadata.delete('trash')
    session.save(validate: false)

    { count: 1, bytes: bytes }
  end

  def restore_single_attachment(attachment_id)
    attachment = Attachment.find_by(id: attachment_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless attachment&.meta&.dig('trash')

    bytes = attachment.meta.dig('trash', 'bytes').to_i
    attachment.meta.delete('trash')
    attachment.save(validate: false)

    { count: 1, bytes: bytes }
  end

  def restore_all_recordings
    count = 0
    bytes = 0
    return { count: 0, bytes: 0 } unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    Telephony::CallSession.where(account_id: @account.id)
                          .where("metadata->'trash' IS NOT NULL")
                          .find_each do |session|
      res = restore_single_recording(session.id)
      count += res[:count]
      bytes += res[:bytes]
    end

    { count: count, bytes: bytes }
  end

  def restore_all_attachments
    count = 0
    bytes = 0

    Attachment.where(account_id: @account.id)
              .where("meta->'trash' IS NOT NULL")
              .find_each do |attachment|
      res = restore_single_attachment(attachment.id)
      count += res[:count]
      bytes += res[:bytes]
    end

    { count: count, bytes: bytes }
  end

  def purge_single_recording(session_id)
    session = Telephony::CallSession.find_by(id: session_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless session&.metadata&.dig('trash')

    trash_meta = session.metadata['trash']
    trash_path = trash_meta['trash_path']
    bytes = trash_meta['bytes'].to_i

    File.delete(trash_path) if trash_path.present? && File.exist?(trash_path)
    session.metadata.delete('trash')
    session.metadata['recording'] ||= {}
    session.metadata['recording']['purged'] = true
    session.metadata['recording']['purged_at'] = Time.current.iso8601
    session.recording_ref = nil
    session.save(validate: false)

    { count: 1, bytes: bytes }
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def purge_single_attachment(attachment_id)
    attachment = Attachment.find_by(id: attachment_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless attachment

    bytes = attachment.meta&.dig('trash', 'bytes').to_i
    bytes = attachment.file.byte_size.to_i if bytes.zero? && attachment.file.attached?
    attachment.file.purge if attachment.file.attached?
    attachment.destroy

    { count: 1, bytes: bytes }
  end

  def purge_all_recordings
    count = 0
    bytes = 0
    return { count: 0, bytes: 0 } unless defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?

    Telephony::CallSession.where(account_id: @account.id)
                          .where("metadata->'trash' IS NOT NULL")
                          .find_each do |session|
      res = purge_single_recording(session.id)
      count += res[:count]
      bytes += res[:bytes]
    end

    { count: count, bytes: bytes }
  end

  def purge_all_attachments
    count = 0
    bytes = 0

    Attachment.where(account_id: @account.id)
              .where("meta->'trash' IS NOT NULL")
              .find_each do |attachment|
      res = purge_single_attachment(attachment.id)
      count += res[:count]
      bytes += res[:bytes]
    end

    { count: count, bytes: bytes }
  end

  def cleanup_trash_directory
    trash_dir = Rails.root.join('storage', 'trash', @account.id.to_s)
    FileUtils.rm_rf(trash_dir)
  rescue StandardError => e
    Rails.logger.warn("[Storage::TrashService] cleanup_trash_directory failed for account #{@account.id}: #{e.message}")
  end

  def resolve_recording_path(session)
    ref = session.recording_ref
    return if ref.blank?

    candidates = [
      Rails.root.join('storage', ref),
      Rails.root.join('storage', 'voice-recordings', 'janus', session.account_id.to_s, File.basename(ref)),
      Rails.root.join('storage', 'voice-recordings', 'sipuni', session.account_id.to_s, File.basename(ref)),
      Rails.root.join('storage', 'voice-recordings', session.account_id.to_s, File.basename(ref))
    ]
    candidates.find { |p| File.exist?(p) }
  end
end
# rubocop:enable Metrics/ClassLength
