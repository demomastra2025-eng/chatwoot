# frozen_string_literal: true

require 'fileutils'

# rubocop:disable Metrics/ClassLength
class Storage::TrashService
  RETENTION_DAYS = 30

  InvalidParams = Class.new(ArgumentError)

  def initialize(account:, actor_id: nil)
    @account = account
    @actor_id = actor_id
  end

  def preview(file_type: 'all', older_than_months: 6, inbox_id: nil)
    filter = cleanup_filter(file_type, older_than_months, inbox_id)
    selection = build_cleanup_selection(filter)
    result = summarize_selection(selection)
    nonce = SecureRandom.hex(24)
    digest = selection_digest(selection)
    Rails.cache.write(manifest_cache_key(nonce), selection, expires_in: 5.minutes)
    claims = cleanup_claims(filter, result, nonce, digest)
    result.merge(confirmation_token: cleanup_verifier.generate(claims, expires_in: 5.minutes, purpose: 'account-storage-cleanup'))
  end

  def validate_cleanup_confirmation!(file_type:, older_than_months:, preview_token:, confirmed:, inbox_id: nil)
    preview, = validated_cleanup_selection!(
      file_type: file_type, older_than_months: older_than_months, inbox_id: inbox_id,
      preview_token: preview_token, confirmed: confirmed
    )
    preview
  end

  def move_to_trash!(file_type: 'all', older_than_months: 6, inbox_id: nil, preview_token: nil, confirmed: false)
    validated_preview, selection = validated_cleanup_selection!(
      file_type: file_type, older_than_months: older_than_months, inbox_id: inbox_id,
      preview_token: preview_token, confirmed: confirmed
    )
    expires_at = RETENTION_DAYS.days.from_now
    moved_recordings = move_recordings_to_trash(selection['recordings'], expires_at)
    moved_attachments = move_attachments_to_trash(selection['attachments'], expires_at)
    total_count = moved_recordings[:count] + moved_attachments[:count]
    request_storage_refresh

    {
      success: true,
      moved_count: total_count,
      moved_bytes: moved_recordings[:bytes] + moved_attachments[:bytes],
      # Moving audio into account trash does not release physical quota; it is still retained for 30 days.
      freed_bytes: 0,
      pending_bytes: moved_recordings[:bytes] + moved_attachments[:bytes],
      retention_days: RETENTION_DAYS,
      expires_at: expires_at.iso8601,
      confirmed_preview_count: validated_preview[:total_count]
    }
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
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

    # 2. Original recordings (the WAV kept after compression) moved here by the retention job
    trashed_original_sessions.find_each do |session|
      trash_meta = session.metadata.dig('recording', 'retained_original', 'trash') || {}
      bytes = trash_meta['bytes'].to_i
      total_bytes += bytes
      items << format_trash_original(session, trash_meta, bytes)
    end

    # 3. Trashed attachments
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
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def restore!(item_type: nil, item_id: nil, restore_all: false)
    restored_count = 0
    restored_bytes = 0

    if restore_all
      results = [restore_all_recordings, restore_all_originals, restore_all_attachments]
      restored_count = results.sum { |res| res[:count] }
      restored_bytes = results.sum { |res| res[:bytes] }
    elsif item_type.to_s == 'recording' && item_id.present?
      res = restore_single_recording(item_id)
      restored_count = res[:count]
      restored_bytes = res[:bytes]
    elsif item_type.to_s == 'original_recording' && item_id.present?
      res = restore_original_recording(item_id)
      restored_count = res[:count]
      restored_bytes = res[:bytes]
    elsif item_type.to_s == 'attachment' && item_id.present?
      res = restore_single_attachment(item_id)
      restored_count = res[:count]
      restored_bytes = res[:bytes]
    end

    request_storage_refresh

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
      results = [purge_all_recordings, purge_all_originals, purge_all_attachments]
      purged_count = results.sum { |res| res[:count] }
      purged_bytes = results.sum { |res| res[:bytes] }
    elsif item_type.to_s == 'recording' && item_id.present?
      res = purge_single_recording(item_id)
      purged_count = res[:count]
      purged_bytes = res[:bytes]
    elsif item_type.to_s == 'original_recording' && item_id.present?
      res = purge_original_recording(item_id)
      purged_count = res[:count]
      purged_bytes = res[:bytes]
    elsif item_type.to_s == 'attachment' && item_id.present?
      res = purge_single_attachment(item_id)
      purged_count = res[:count]
      purged_bytes = res[:bytes]
    end

    request_storage_refresh

    {
      success: true,
      purged_count: purged_count,
      purged_bytes: purged_bytes
    }
  end

  # Nightly purge. Works account by account so that every query stays on the account_id index and
  # one failing account (or file) can never stop the purge for everybody else.
  def self.purge_expired_all!
    totals = { purged_count: 0, purged_bytes: 0, failed_count: 0 }

    Account.find_each do |account|
      result = new(account: account).purge_expired!
      totals.each_key { |key| totals[key] += result[key] }
    rescue StandardError => e
      totals[:failed_count] += 1
      Rails.logger.error("[Storage::TrashService] Purge failed for account #{account.id}: #{e.class.name}: #{e.message}")
    end

    Rails.logger.info("[Storage::TrashService] Purged expired trash: #{totals.inspect}")
    totals
  end

  def purge_expired!
    now_iso = Time.current.iso8601
    result = { purged_count: 0, purged_bytes: 0, failed_count: 0 }

    expired_recordings(now_iso).find_each { |session| purge_expired_item(result) { purge_single_recording(session.id) } }
    expired_original_recordings(now_iso).find_each { |session| purge_expired_item(result) { purge_original_recording(session.id) } }
    expired_attachments(now_iso).find_each { |attachment| purge_expired_item(result) { purge_single_attachment(attachment.id) } }

    result
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # Moves an expired original recording (the WAV kept after compression) into the account trash for
  # RETENTION_DAYS and notes it in the call metadata so an administrator can restore it. The caller holds the
  # recording lock and the call session row lock. Returns the moved byte size.
  def trash_retained_original!(session, path)
    trash_path = retained_original_trash_path(session, path)
    unless Storage::RecordingPaths.within_account?(trash_path, account_id: @account.id, include_trash: true)
      raise InvalidParams, I18n.t('storage_management.errors.trash_path_rejected')
    end

    byte_size = File.size(path)
    move_file_exclusively(path.to_s, trash_path)
    begin
      write_retained_original_trash(session, path.to_s, trash_path, byte_size)
    rescue StandardError
      move_file_exclusively(trash_path, path.to_s) if File.exist?(trash_path) && !File.exist?(path.to_s)
      raise
    end
    byte_size
  end

  def retained_original_trash_path(session, path)
    Storage::RecordingPaths.prepare_trash_directory(@account.id).join("#{session.id}_retained_#{File.basename(path)}").to_s
  end

  # Puts a moved original back when the transaction that publishes its trash manifest did not commit.
  def undo_retained_original_move(path, trash_path)
    move_file_exclusively(trash_path, path.to_s) if File.exist?(trash_path) && !File.exist?(path.to_s)
  end

  private

  def request_storage_refresh
    Accounts::StorageOverviewService.new(account: @account).invalidate!
  end

  def write_retained_original_trash(session, original_path, trash_path, byte_size)
    now = Time.current
    metadata = (session.metadata || {}).deep_dup
    metadata['recording']['retained_original']['trash'] = {
      'deleted_at' => now.iso8601,
      'expires_at' => (now + RETENTION_DAYS.days).iso8601,
      'original_path' => original_path,
      'trash_path' => trash_path,
      'bytes' => byte_size
    }
    session.metadata = metadata
    session.save!(validate: false)
  end

  def human_size(bytes)
    ActiveSupport::NumberHelper.number_to_human_size(bytes.to_i)
  end

  # A caller must choose the age filter and review a short-lived signed preview before moving any files.
  # These independent filters reject unknown types, invalid ages and cross-account inbox IDs.
  # rubocop:disable Metrics/CyclomaticComplexity
  def cleanup_filter(file_type, months, inbox_id)
    type = file_type.to_s.presence || 'all'
    allowed = %w[all recordings attachments image audio video file]
    raise InvalidParams, I18n.t('storage_management.errors.invalid_file_type') unless allowed.include?(type)

    month_count = Integer(months, exception: false)
    raise InvalidParams, I18n.t('storage_management.errors.invalid_age_filter') unless month_count&.between?(1, 120)

    normalized_inbox_id = inbox_id.presence&.to_s
    if normalized_inbox_id.present? && !@account.inboxes.exists?(id: normalized_inbox_id)
      raise InvalidParams, I18n.t('storage_management.errors.invalid_inbox')
    end

    { file_type: type, older_than_months: month_count, inbox_id: normalized_inbox_id }
  end
  # rubocop:enable Metrics/CyclomaticComplexity

  def cleanup_claims(filter, result, nonce, digest)
    {
      'account_id' => @account.id,
      'actor_id' => @actor_id&.to_s,
      'filter' => filter.deep_stringify_keys,
      'manifest_nonce' => nonce,
      'manifest_digest' => digest,
      'total_count' => result[:total_count].to_i,
      'total_bytes' => result[:total_bytes].to_i,
      'recordings_count' => result[:recordings_count].to_i,
      'recordings_bytes' => result[:recordings_bytes].to_i,
      'attachments_count' => result[:attachments_count].to_i,
      'attachments_bytes' => result[:attachments_bytes].to_i
    }
  end

  # Each token, actor, tenant, filter and exact manifest check is required before executing destructive selection.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def validated_cleanup_selection!(file_type:, older_than_months:, inbox_id:, preview_token:, confirmed:)
    filter = cleanup_filter(file_type, older_than_months, inbox_id)
    raise InvalidParams, I18n.t('storage_management.errors.confirmation_required') unless ActiveModel::Type::Boolean.new.cast(confirmed)

    claims = cleanup_verifier.verified(preview_token.to_s, purpose: 'account-storage-cleanup')
    raise InvalidParams, I18n.t('storage_management.errors.preview_expired') unless claims.is_a?(Hash)
    raise InvalidParams, I18n.t('storage_management.errors.preview_changed') unless claims['account_id'].to_s == @account.id.to_s
    raise InvalidParams, I18n.t('storage_management.errors.preview_changed') unless claims['actor_id'] == @actor_id&.to_s
    raise InvalidParams, I18n.t('storage_management.errors.preview_changed') unless claims['filter'] == filter.deep_stringify_keys

    nonce = claims['manifest_nonce'].to_s
    selection = Rails.cache.read(manifest_cache_key(nonce))
    raise InvalidParams, I18n.t('storage_management.errors.preview_expired') unless selection.is_a?(Hash)
    raise InvalidParams, I18n.t('storage_management.errors.preview_changed') unless selection_digest(selection) == claims['manifest_digest']

    current_selection = build_cleanup_selection(filter)
    raise InvalidParams, I18n.t('storage_management.errors.preview_changed') unless selection_digest(current_selection) == claims['manifest_digest']

    current_preview = summarize_selection(current_selection)
    expected_claims = cleanup_claims(filter, current_preview, nonce, claims['manifest_digest'])
    raise InvalidParams, I18n.t('storage_management.errors.preview_changed') unless claims == expected_claims

    [current_preview, current_selection]
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    raise InvalidParams, I18n.t('storage_management.errors.preview_expired')
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  def manifest_cache_key(nonce)
    "account-storage-cleanup:#{@account.id}:#{@actor_id}:#{nonce}"
  end

  def selection_digest(selection)
    Digest::SHA256.hexdigest(JSON.generate(selection))
  end

  def build_cleanup_selection(filter)
    cutoff = cutoff_timestamp(filter[:older_than_months])
    recordings = if call_sessions_available? && %w[image video file].exclude?(filter[:file_type])
                   recordings_scope(cutoff, filter[:inbox_id]).includes(:inbox).order(:id).filter_map do |session|
                     recording_selection_entry(session)
                   end
                 else
                   []
                 end
    attachments = attachment_cleanup_scope(cutoff, filter[:inbox_id], filter[:file_type])
                  .includes(:message, file_attachment: :blob).order(:id)
                  .map { |attachment| attachment_selection_entry(attachment) }
    { 'recordings' => recordings, 'attachments' => attachments }
  end

  def summarize_selection(selection)
    recordings = selection['recordings']
    attachments = selection['attachments']
    recording_bytes = recordings.sum { |item| item['byte_size'].to_i }
    attachment_bytes = attachments.sum { |item| item['byte_size'].to_i }
    samples = (recordings.map { |item| cleanup_sample(item, 'recording') } +
      attachments.map { |item| cleanup_sample(item, 'attachment') })
              .sort_by { |item| -item[:byte_size] }.first(20)

    {
      total_count: recordings.size + attachments.size,
      total_bytes: recording_bytes + attachment_bytes,
      recordings_count: recordings.size,
      recordings_bytes: recording_bytes,
      attachments_count: attachments.size,
      attachments_bytes: attachment_bytes,
      retention_days: RETENTION_DAYS,
      samples: samples
    }
  end

  def cleanup_sample(item, item_type)
    {
      id: item['id'],
      item_type: item_type,
      file_name: I18n.t("storage_management.item_labels.#{item_type == 'recording' ? 'audio_recording' : 'file'}"),
      file_type: item_type == 'recording' ? 'audio' : item['file_type'],
      byte_size: item['byte_size'].to_i,
      created_at: item['created_at'],
      inbox_id: item['inbox_id'],
      inbox_name: item['inbox_name']
    }
  end

  def recording_selection_entry(session)
    entries = recording_file_entries(session)
    return if entries.none? { |entry| entry[:role] == 'current' }

    {
      'id' => session.id,
      'recording_ref' => session.recording_ref,
      'files' => entries.map { |entry| entry.slice(:role, :storage_key, :original_path, :byte_size).stringify_keys },
      'byte_size' => entries.sum { |entry| entry[:byte_size].to_i },
      'created_at' => session.created_at.iso8601,
      'inbox_id' => session.inbox_id,
      'inbox_name' => session.inbox&.name
    }
  end

  def attachment_cleanup_scope(cutoff_date, inbox_id, file_type)
    return Attachment.none if file_type == 'recordings'

    scope = Attachment.joins(:file_blob).where(account_id: @account.id)
                      .where("(attachments.meta->'trash') IS NULL")
    scope = scope.where('attachments.created_at < ?', cutoff_date) if cutoff_date.present?
    scope = scope.joins(:message).where(messages: { inbox_id: inbox_id }) if inbox_id.present?
    scope = scope.where(file_type: file_type) if file_type.present? && %w[all attachments].exclude?(file_type)
    scope
  end

  def attachment_selection_entry(attachment)
    message = attachment.message
    blob = attachment.file.attached? ? attachment.file.blob : nil
    {
      'id' => attachment.id,
      'blob_id' => blob&.id,
      'byte_size' => blob&.byte_size.to_i,
      'file_type' => attachment.file_type,
      'message_id' => message&.id,
      'inbox_id' => message&.inbox_id,
      'inbox_name' => message&.inbox&.name,
      'created_at' => attachment.created_at.iso8601
    }
  end

  def cleanup_verifier
    @cleanup_verifier ||= ActiveSupport::MessageVerifier.new(
      Rails.application.key_generator.generate_key('account-storage-cleanup-preview', 32)
    )
  end

  def cutoff_timestamp(months)
    Integer(months).months.ago
  end

  def call_sessions_available?
    defined?(Telephony::CallSession) && Telephony::CallSession.table_exists?
  end

  def expired_recordings(now_iso)
    return Telephony::CallSession.none unless call_sessions_available?

    Telephony::CallSession.where(account_id: @account.id).where("(metadata->'trash'->>'expires_at') <= ?", now_iso)
  end

  def expired_attachments(now_iso)
    Attachment.where(account_id: @account.id).where("(meta->'trash'->>'expires_at') <= ?", now_iso)
  end

  def trashed_original_sessions
    return Telephony::CallSession.none unless call_sessions_available?

    Telephony::CallSession.where(account_id: @account.id)
                          .where("metadata #> '{recording,retained_original,trash}' IS NOT NULL")
                          .includes(:inbox)
  end

  def expired_original_recordings(now_iso)
    return Telephony::CallSession.none unless call_sessions_available?

    Telephony::CallSession.where(account_id: @account.id)
                          .where("(metadata #>> '{recording,retained_original,trash,expires_at}') <= ?", now_iso)
  end

  def purge_expired_item(result)
    purged = yield
    result[:purged_count] += purged[:count]
    result[:purged_bytes] += purged[:bytes]
  rescue StandardError => e
    result[:failed_count] += 1
    Rails.logger.error("[Storage::TrashService] Failed to purge expired item of account #{@account.id}: #{e.class.name}: #{e.message}")
  end

  def preview_recordings(cutoff_date, inbox_id, file_type)
    return { count: 0, bytes: 0, samples: [] } if %w[image video file].include?(file_type)
    return { count: 0, bytes: 0, samples: [] } unless call_sessions_available?

    count = 0
    total_bytes = 0
    samples = []
    recordings_scope(cutoff_date, inbox_id).includes(:inbox).find_each do |session|
      entries = recording_file_entries(session)
      next if entries.none? { |entry| entry[:role] == 'current' }

      size = entries.sum { |entry| entry[:byte_size] }
      count += 1
      total_bytes += size
      samples << preview_sample(session, size) if samples.size < 10
    end
    { count: count, bytes: total_bytes, samples: samples }
  end

  def preview_sample(session, size)
    {
      id: session.id,
      item_type: 'recording',
      file_name: I18n.t('storage_management.item_labels.audio_recording'),
      file_type: 'audio',
      byte_size: size,
      created_at: session.created_at.iso8601,
      inbox_id: session.inbox_id,
      inbox_name: session.inbox&.name
    }
  end

  # Active and retained local-file metadata stay in one tenant-safe accounting entry.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength
  def recording_file_entries(session)
    entries = []
    current_path = resolve_recording_path(session)
    if current_path
      entries << {
        role: 'current', storage_key: session.recording_ref, original_path: current_path.to_s,
        byte_size: File.size(current_path)
      }
    end

    retained = session.metadata.to_h.dig('recording', 'retained_original')
    if retained.is_a?(Hash) && retained['purged_at'].blank?
      retained_key = retained['storage_key'].to_s
      retained_path = Storage::RecordingPaths.resolve(retained_key, account_id: session.account_id)
      if retained_path && entries.none? { |entry| entry[:original_path] == retained_path.to_s }
        entries << {
          role: 'retained_original', storage_key: retained_key, original_path: retained_path.to_s,
          byte_size: File.size(retained_path)
        }
      end
    end
    entries
  rescue SystemCallError
    []
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength
  def recordings_scope(cutoff_date, inbox_id)
    scope = Telephony::CallSession.where(account_id: @account.id)
                                  .where.not(recording_ref: [nil, ''])
                                  .where("(metadata->'trash') IS NULL")
    scope = scope.where('created_at < ?', cutoff_date) if cutoff_date.present?
    inbox_id.present? ? scope.where(inbox_id: inbox_id) : scope
  end

  # The query, bounded samples and inbox/file filters form one preview contract.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
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
        file_name: I18n.t('storage_management.item_labels.file'),
        file_type: att.file_type,
        byte_size: blob.byte_size.to_i,
        created_at: att.created_at.iso8601,
        inbox_id: att.message&.inbox_id,
        inbox_name: att.message&.inbox&.name
      }
    end

    { count: count, bytes: bytes, samples: samples }
  end

  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def move_recordings_to_trash(selected_items, expires_at)
    return { count: 0, bytes: 0 } if selected_items.empty?

    trash_dir = Storage::RecordingPaths.prepare_trash_directory(@account.id)
    result = { count: 0, bytes: 0 }
    selected_items.each do |expected|
      session = Telephony::CallSession.find_by(id: expected['id'], account_id: @account.id)
      next unless session

      keys = Array(expected['files']).map { |entry| entry['storage_key'] }
      moved_bytes = Storage::RecordingLock.synchronize(account_id: @account.id, storage_keys: keys) do
        move_recording_to_trash_locked(session, expected, trash_dir, expires_at)
      end
      next unless moved_bytes

      result[:count] += 1
      result[:bytes] += moved_bytes
    end
    result
  end

  # The row lock, path checks, reference detachment and rollback stay in one destructive critical section.
  # rubocop:disable Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def move_recording_to_trash_locked(session, expected, trash_dir, expires_at)
    manifest = []
    moved_bytes = nil
    session.with_lock do
      session.reload
      current = recording_selection_entry(session)
      next unless current && selection_digest({ 'item' => current }) == selection_digest({ 'item' => expected })

      entries = recording_file_entries(session)
      reference_keys = entries.flat_map do |entry|
        Storage::RecordingPaths.reference_aliases(entry[:original_path], account_id: @account.id)
      end.uniq

      source_paths = entries.map { |entry| entry[:original_path] }
      reference_manifest_id = SecureRandom.hex(24)
      reference_patches = detach_recording_references!(session, reference_keys, source_paths, reference_manifest_id, entries)
      if shared_recording_reference?(session, entries, include_current_conversation: true)
        raise InvalidParams, I18n.t('storage_management.errors.recording_reference_ambiguous')
      end

      entries.each do |entry|
        trash_path = trash_dir.join("#{session.id}_#{entry[:role]}_#{File.basename(entry[:original_path])}").to_s
        raise InvalidParams, I18n.t('storage_management.errors.trash_target_exists') if File.exist?(trash_path) || File.symlink?(trash_path)
        unless Storage::RecordingPaths.within_account?(
          trash_path, account_id: @account.id, include_trash: true
        )
          raise InvalidParams, I18n.t('storage_management.errors.trash_path_rejected')
        end

        move_file_exclusively(entry[:original_path], trash_path)
        manifest << entry.merge(trash_path: trash_path)
        raise InvalidParams, I18n.t('storage_management.errors.trash_path_rejected') unless trash_path_deletable?(trash_path)
      end

      current_entry = manifest.find { |entry| entry[:role] == 'current' }
      session.metadata = (session.metadata || {}).deep_dup
      session.metadata['trash'] = {
        'deleted_at' => Time.current.iso8601,
        'expires_at' => expires_at.iso8601,
        'original_recording_ref' => current_entry[:storage_key],
        'original_path' => current_entry[:original_path],
        'trash_path' => current_entry[:trash_path],
        'files' => manifest.map(&:stringify_keys),
        'reference_manifest_id' => reference_manifest_id,
        'reference_patches' => reference_patches,
        'bytes' => manifest.sum { |entry| entry[:byte_size].to_i }
      }
      session.recording_ref = nil
      session.save!(validate: false)
      moved_bytes = manifest.sum { |entry| entry[:byte_size].to_i }
    end
    moved_bytes
  rescue StandardError => e
    manifest.to_a.reverse_each do |entry|
      move_file_exclusively(entry[:trash_path], entry[:original_path]) if File.exist?(entry[:trash_path]) && !File.exist?(entry[:original_path])
    rescue StandardError
      Rails.logger.error("[Storage::TrashService] Could not roll back recording move for call session #{session.id}")
    end
    Rails.logger.error("[Storage::TrashService] Could not trash recording of call session #{session.id}: #{e.class.name}")
    nil
  end
  # rubocop:enable Metrics/BlockLength, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # Check candidates by indexed aliases, then confirm ambiguous basenames against the physical file.
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def shared_recording_reference?(session, entries, include_current_conversation: false)
    entries.any? do |entry|
      path = entry[:original_path]
      keys = Storage::RecordingPaths.reference_aliases(path, account_id: @account.id)
      next false if keys.empty?

      other_sessions = Telephony::CallSession.where(account_id: @account.id).where.not(id: session.id)
      session_candidates = call_session_recording_references(other_sessions, keys)
      next true if session_candidates.find_each.any? do |candidate|
        values = call_session_recording_values(candidate)
        values.any? do |reference|
          recording_reference_matches_paths?(
            reference, keys, [path], qualified_references: values, conservative: true
          )
        end
      end

      messages = message_recording_references(keys)
      if session.conversation_id.present? && !include_current_conversation
        messages = messages.where('messages.conversation_id IS NULL OR messages.conversation_id != ?', session.conversation_id)
      end
      next true if messages.find_each.any? do |message|
        values = message_recording_values(message)
        values.any? do |reference|
          recording_reference_matches_paths?(
            reference, keys, [path], qualified_references: values, conservative: true
          )
        end
      end

      conversations = conversation_recording_references(keys)
      if session.conversation_id.present? && !include_current_conversation
        conversations = conversations.where.not(id: session.conversation_id)
      end
      conversations.find_each.any? do |conversation|
        values = conversation_recording_values(conversation)
        values.any? do |reference|
          recording_reference_matches_paths?(
            reference, keys, [path], qualified_references: values, conservative: true
          )
        end
      end
    end
  end

  def message_recording_values(message)
    data = message.content_attributes.to_h['data']
    recording = data.is_a?(Hash) ? data['recording'] : nil
    [
      data.is_a?(Hash) ? data['storage_key'] : nil,
      data.is_a?(Hash) ? data['recording_ref'] : nil,
      recording.is_a?(Hash) ? recording['storage_key'] : nil,
      recording.is_a?(Hash) ? recording['recording_ref'] : nil,
      recording.is_a?(Hash) ? recording.dig('retained_original', 'storage_key') : nil
    ]
  end

  def conversation_recording_values(conversation)
    attributes = conversation.additional_attributes
    recording = attributes.is_a?(Hash) ? attributes['recording'] : nil
    [
      recording.is_a?(Hash) ? recording['storage_key'] : nil,
      recording.is_a?(Hash) ? recording['recording_ref'] : nil,
      recording.is_a?(Hash) ? recording.dig('retained_original', 'storage_key') : nil,
      attributes.is_a?(Hash) ? attributes['storage_key'] : nil,
      attributes.is_a?(Hash) ? attributes['recording_ref'] : nil
    ]
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def message_recording_references(keys)
    Message.where(account_id: @account.id).with_recording_reference_candidates(keys)
  end

  def call_session_recording_references(scope, keys)
    scope.where(<<~SQL.squish, refs: keys)
      recording_ref IN (:refs) OR
      metadata #>> '{recording,storage_key}' IN (:refs) OR
      metadata #>> '{recording,recording_ref}' IN (:refs) OR
      metadata #>> '{recording,retained_original,storage_key}' IN (:refs) OR
      metadata #>> '{trash,original_recording_ref}' IN (:refs) OR
      metadata #>> '{trash,original_path}' IN (:refs) OR
      metadata #>> '{trash,trash_path}' IN (:refs) OR
      EXISTS (
        SELECT 1
        FROM jsonb_array_elements(
          CASE WHEN jsonb_typeof(metadata #> '{trash,files}') = 'array'
               THEN metadata #> '{trash,files}' ELSE '[]'::jsonb END
        ) AS manifest_file(value)
        WHERE manifest_file.value->>'storage_key' IN (:refs)
          OR manifest_file.value->>'original_path' IN (:refs)
          OR manifest_file.value->>'trash_path' IN (:refs)
      )
    SQL
  end

  def call_session_recording_values(session)
    metadata = session.metadata.to_h
    trash = metadata['trash'].is_a?(Hash) ? metadata['trash'] : {}
    manifest_values = Array(trash['files']).flat_map do |entry|
      %w[storage_key original_path trash_path].map { |key| entry[key] }
    end
    [
      session.recording_ref,
      metadata.dig('recording', 'storage_key'),
      metadata.dig('recording', 'recording_ref'),
      metadata.dig('recording', 'retained_original', 'storage_key'),
      trash['original_recording_ref'],
      trash['original_path'],
      trash['trash_path'],
      *manifest_values
    ].compact_blank
  end

  def conversation_recording_references(keys)
    Conversation.where(account_id: @account.id).where(
      "additional_attributes #>> '{storage_key}' IN (:refs) OR " \
      "additional_attributes #>> '{recording,storage_key}' IN (:refs) OR " \
      "additional_attributes #>> '{recording,recording_ref}' IN (:refs) OR " \
      "additional_attributes #>> '{recording,retained_original,storage_key}' IN (:refs) OR " \
      "additional_attributes #>> '{recording_ref}' IN (:refs)",
      refs: keys
    )
  end

  # Locked transcript/message and conversation patches preserve unrelated JSON fields.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def detach_recording_references!(session, keys, source_paths, manifest_id, source_entries)
    return [] if keys.empty? || session.conversation_id.blank?

    patches = []
    message_recording_references(keys).where(conversation_id: session.conversation_id).find_each do |candidate|
      candidate.with_lock do
        message = Message.find_by(id: candidate.id, account_id: @account.id, conversation_id: session.conversation_id)
        next unless message

        attributes = message.content_attributes.is_a?(Hash) ? message.content_attributes.deep_dup : {}
        data = attributes['data'].is_a?(Hash) ? attributes['data'].deep_dup : {}
        patch = detach_recording_payload!(data, keys, source_paths, source_entries)
        next unless patch

        attributes['data'] = data
        message.update_columns(content_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        patches << patch.merge(
          'record_type' => 'message',
          'record_id' => message.id,
          'session_id' => session.id,
          'manifest_id' => manifest_id
        )
      end
    end

    conversation = Conversation.find_by(id: session.conversation_id, account_id: @account.id)
    return patches unless conversation

    conversation.with_lock do
      conversation.reload
      attributes = conversation.additional_attributes
      next unless attributes.is_a?(Hash)

      attributes = attributes.deep_dup
      patch = detach_recording_payload!(attributes, keys, source_paths, source_entries)
      next unless patch

      conversation.update!(additional_attributes: attributes)
      patches << patch.merge(
        'record_type' => 'conversation',
        'record_id' => conversation.id,
        'session_id' => session.id,
        'manifest_id' => manifest_id
      )
    end
    patches
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # Nested and legacy recording reference forms are detached together to avoid stale playback paths.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def detach_recording_payload!(data, keys, source_paths, source_entries)
    prior = recording_reference_snapshot(data)
    qualified_references = payload_recording_values(data)
    changed = false
    %w[recording_ref storage_key].each do |key|
      next unless recording_reference_matches_paths?(
        data[key], keys, source_paths, qualified_references: qualified_references
      )

      data.delete(key)
      changed = true
    end

    recording = data['recording']
    recording = recording.is_a?(Hash) ? recording.deep_dup : {}
    changed = clear_recording_path_fields!(
      recording, keys, source_paths, qualified_references: qualified_references
    ) || changed
    return unless changed

    recording['status'] = 'trashed'
    data['recording'] = recording
    data.delete('recording_url')
    after = recording_reference_snapshot(data)
    patch = { 'prior' => prior, 'after' => after }
    restore_values = canonical_detached_reference_values(prior, after, source_entries, qualified_references)
    patch['restore_reference_values'] = restore_values if restore_values.present?
    patch
  end

  def recording_reference_field_paths
    %w[recording_ref storage_key recording.storage_key recording.recording_ref recording.retained_original.storage_key]
  end

  def canonical_detached_reference_values(prior, after, source_entries, qualified_references)
    prior_fields = prior.fetch('fields')
    after_fields = after.fetch('fields')
    recording_reference_field_paths.each_with_object({}) do |path, values|
      previous = prior_fields[path]
      current = after_fields[path]
      next unless previous&.dig('present') && current && !current['present']

      reference = previous['value']
      next unless reference.is_a?(String) && !Storage::RecordingPaths.qualified_reference?(reference)

      matches = source_entries.filter_map do |entry|
        original_path = entry[:original_path]
        next if original_path.blank?

        aliases = Storage::RecordingPaths.reference_aliases(original_path, account_id: @account.id)
        canonical_reference = aliases[1]
        next if canonical_reference.blank? || !Storage::RecordingPaths.qualified_reference?(canonical_reference)
        next unless recording_reference_matches_paths?(
          reference, aliases, [original_path], qualified_references: qualified_references
        )
        next unless Storage::RecordingPaths.same_physical_file?(
          canonical_reference, original_path, account_id: @account.id
        )

        canonical_reference
      end
      values[path] = matches.first if matches.one?
    end
  end

  def recording_reference_snapshot(data)
    paths = [
      %w[recording_ref], %w[storage_key], %w[recording_url],
      %w[recording storage_key], %w[recording recording_ref], %w[recording recording_url],
      %w[recording status], %w[recording retained_original storage_key],
      %w[recording retained_original status]
    ]
    fields = paths.to_h do |path|
      parent = data
      path[0...-1].each do |key|
        parent = parent.is_a?(Hash) ? parent[key] : nil
      end
      present = parent.is_a?(Hash) && parent.key?(path.last)
      [path.join('.'), { 'present' => present, 'value' => (parent[path.last].deep_dup if present) }]
    end
    recording = data['recording']
    {
      'fields' => fields,
      'recording_container' => recording.is_a?(Hash),
      'retained_original_container' => recording.is_a?(Hash) && recording['retained_original'].is_a?(Hash)
    }
  end

  def restore_recording_payload_patch!(data, patch)
    return false unless recording_reference_snapshot(data) == patch['after']

    patch.dig('prior', 'fields').each do |path, entry|
      parts = path.split('.')
      parent = data
      parts[0...-1].each do |key|
        parent[key] = {} unless parent[key].is_a?(Hash)
        parent = parent[key]
      end
      if entry['present']
        restore_values = patch['restore_reference_values'].is_a?(Hash) ? patch['restore_reference_values'] : {}
        value = restore_values.key?(path) ? restore_values[path] : entry['value']
        parent[parts.last] = value.deep_dup
      else
        parent.delete(parts.last)
      end
    end

    recording = data['recording']
    if !patch.dig('prior', 'recording_container') && recording.is_a?(Hash) && recording.empty?
      data.delete('recording')
    elsif recording.is_a?(Hash) && !patch.dig('prior', 'retained_original_container') &&
          recording['retained_original'].is_a?(Hash) && recording['retained_original'].empty?
      recording.delete('retained_original')
    end
    true
  end

  def recording_reference_matches_paths?(
    reference, keys, source_paths, qualified_references: [], conservative: false
  )
    Storage::RecordingPaths.reference_matches_paths?(
      reference, source_paths, account_id: @account.id, aliases: keys,
      qualified_references: qualified_references, conservative: conservative
    )
  end

  def payload_recording_values(data)
    recording = data['recording'].is_a?(Hash) ? data['recording'] : {}
    retained = recording['retained_original'].is_a?(Hash) ? recording['retained_original'] : {}
    [
      data['storage_key'], data['recording_ref'], recording['storage_key'], recording['recording_ref'],
      retained['storage_key']
    ].compact_blank
  end

  def clear_recording_path_fields!(recording, keys, source_paths, qualified_references: [])
    changed = false
    %w[storage_key recording_ref].each do |key|
      next unless recording_reference_matches_paths?(
        recording[key], keys, source_paths, qualified_references: qualified_references
      )

      recording.delete(key)
      changed = true
    end
    retained = recording['retained_original']
    if retained.is_a?(Hash) && recording_reference_matches_paths?(
      retained['storage_key'], keys, source_paths, qualified_references: qualified_references
    )
      retained = retained.deep_dup
      retained.delete('storage_key')
      retained['status'] = 'trashed'
      recording['retained_original'] = retained
      changed = true
    end
    recording.delete('recording_url') if changed
    changed
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def move_file_exclusively(source, destination)
    File.link(source, destination)
    identity = File.stat(destination).then { |stat| [stat.dev, stat.ino] }
    File.unlink(source)
    identity
  rescue Errno::EEXIST
    raise InvalidParams, I18n.t('storage_management.errors.trash_target_exists')
  rescue StandardError
    unlink_if_identity_matches(destination, identity) if identity
    raise
  end

  def unlink_if_identity_matches(path, identity)
    return unless File.exist?(path)

    stat = File.stat(path)
    File.unlink(path) if identity == [stat.dev, stat.ino]
  rescue Errno::ENOENT
    nil
  end

  # The attachment row is reloaded and its manifest rechecked inside the tenant row lock.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def move_attachments_to_trash(selected_items, expires_at)
    result = { count: 0, bytes: 0 }
    selected_items.each do |expected|
      attachment = Attachment.find_by(id: expected['id'], account_id: @account.id)
      next unless attachment

      moved_size = nil
      attachment.with_lock do
        attachment.reload
        current = attachment_selection_entry(attachment)
        next unless current == expected && attachment.meta.to_h['trash'].blank?
        next unless attachment.account_id == @account.id

        moved_size = current['byte_size'].to_i
        attachment.meta = (attachment.meta || {}).deep_dup
        attachment.meta['trash'] = {
          'deleted_at' => Time.current.iso8601,
          'expires_at' => expires_at.iso8601,
          'bytes' => moved_size
        }
        attachment.save!(validate: false)
      end
      next if moved_size.nil?

      result[:bytes] += moved_size
      result[:count] += 1
    end
    result
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def format_trash_session(session, trash_meta, bytes)
    expires_at = trash_meta['expires_at']
    days_remaining = calculate_days_remaining(expires_at)

    {
      id: session.id,
      item_type: 'recording',
      file_name: I18n.t('storage_management.item_labels.audio_recording'),
      file_type: 'audio',
      byte_size: bytes,
      deleted_at: trash_meta['deleted_at'],
      expires_at: expires_at,
      days_remaining: days_remaining,
      inbox_id: session.inbox_id,
      inbox_name: session.inbox&.name
    }
  end

  def format_trash_original(session, trash_meta, bytes)
    expires_at = trash_meta['expires_at']

    {
      id: session.id,
      item_type: 'original_recording',
      file_name: I18n.t('storage_management.item_labels.original_recording'),
      file_type: 'audio',
      byte_size: bytes,
      deleted_at: trash_meta['deleted_at'],
      expires_at: expires_at,
      days_remaining: calculate_days_remaining(expires_at),
      inbox_id: session.inbox_id,
      inbox_name: session.inbox&.name
    }
  end

  def format_trash_attachment(attachment, trash_meta, bytes)
    expires_at = trash_meta['expires_at']
    days_remaining = calculate_days_remaining(expires_at)
    attachment.file.attached? ? attachment.file.blob : nil

    {
      id: attachment.id,
      item_type: 'attachment',
      file_name: I18n.t('storage_management.item_labels.file'),
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

  # File restoration, reference restoration and session metadata update form one guarded operation.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def restore_single_recording(session_id)
    session = Telephony::CallSession.find_by(id: session_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless session

    expected_keys = trash_storage_keys(session)
    trash_meta = nil
    restored = false
    moved_entries = []
    Storage::RecordingLock.synchronize(account_id: @account.id, storage_keys: expected_keys) do
      session.with_lock do
        begin
          session.reload
          trash_meta = session.metadata.to_h['trash']&.deep_dup
          next unless trash_meta.is_a?(Hash) && session.recording_ref.blank?
          next unless trash_storage_keys(session) == expected_keys
          next unless restore_recording_files(trash_meta, moved_entries)

          session.metadata = (session.metadata || {}).deep_dup
          session.recording_ref = trash_meta['original_recording_ref']
          session.metadata.delete('trash')
          session.save!(validate: false)
          restore_recording_references!(session, trash_meta, moved_entries)
          restored = true
        rescue StandardError
          rollback_restored_recording_files(moved_entries)
          raise
        end
      end
    end
    { count: restored ? 1 : 0, bytes: restored ? trash_meta['bytes'].to_i : 0 }
  end

  def trash_storage_keys(session)
    trash_meta = session.metadata.to_h['trash']
    files = Array(trash_meta&.[]('files'))
    files.flat_map { |entry| [entry['storage_key'], entry['original_path']] }.compact_blank.presence ||
      [trash_meta&.[]('original_recording_ref')].compact_blank
  end

  # Restore only the exact rows and fields recorded by this trash manifest.
  def restore_recording_references!(session, trash_meta, moved_entries)
    manifest_id = trash_meta['reference_manifest_id'].to_s
    return if manifest_id.blank?

    Array(trash_meta['reference_patches']).each do |patch|
      next unless patch['session_id'].to_i == session.id && patch['manifest_id'] == manifest_id

      restore_values = validated_restore_reference_values(patch, trash_meta, moved_entries)
      restore_patch = patch.merge('restore_reference_values' => restore_values)
      case patch['record_type']
      when 'message'
        restore_message_reference_patch!(session, restore_patch)
      when 'conversation'
        restore_conversation_reference_patch!(session, restore_patch)
      end
    end
  end

  def validated_restore_reference_values(patch, trash_meta, moved_entries)
    values = patch['restore_reference_values']
    return {} unless values.is_a?(Hash)

    Array(moved_entries).then do |restored_entries|
      values.each_with_object({}) do |(field, reference), validated|
        next unless recording_reference_field_paths.include?(field)
        next unless reference.is_a?(String) && Storage::RecordingPaths.qualified_reference?(reference)

        path = Storage::RecordingPaths.resolve(reference, account_id: @account.id)
        next unless path

        original_path = path.to_s
        next unless Storage::RecordingPaths.contained_in_account?(
          original_path, account_id: @account.id, include_trash: false
        )
        next unless Storage::RecordingPaths.reference_aliases(original_path, account_id: @account.id)[1] == reference

        manifest_matches = Array(trash_meta['files']).select do |entry|
          entry.is_a?(Hash) && entry['original_path'].to_s == original_path
        end
        moved_matches = restored_entries.select { |entry| entry['original_path'].to_s == original_path }
        next unless manifest_matches.one? && moved_matches.one?
        next unless File.file?(original_path) && !File.symlink?(original_path)

        stat = File.stat(original_path)
        next unless moved_matches.first['restored_identity'] == [stat.dev, stat.ino]

        validated[field] = reference
      rescue SystemCallError
        next
      end
    end
  end

  def restore_message_reference_patch!(session, patch)
    return if session.conversation_id.blank?

    candidate = Message.find_by(
      id: patch['record_id'], account_id: @account.id, conversation_id: session.conversation_id
    )
    return unless candidate

    candidate.with_lock do
      message = Message.find_by(id: candidate.id, account_id: @account.id, conversation_id: session.conversation_id)
      next unless message

      attributes = message.content_attributes.is_a?(Hash) ? message.content_attributes.deep_dup : {}
      data = attributes['data'].is_a?(Hash) ? attributes['data'].deep_dup : {}
      next unless restore_recording_payload_patch!(data, patch)

      attributes['data'] = data
      message.update_columns(content_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def restore_conversation_reference_patch!(session, patch)
    return if session.conversation_id.blank? || patch['record_id'].to_i != session.conversation_id

    conversation = Conversation.find_by(id: session.conversation_id, account_id: @account.id)
    return unless conversation

    conversation.with_lock do
      conversation.reload
      attributes = conversation.additional_attributes
      next unless attributes.is_a?(Hash)

      updated = attributes.deep_dup
      next unless restore_recording_payload_patch!(updated, patch)

      conversation.update!(additional_attributes: updated)
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # Every destination is validated before moves, and partial restoration rolls files back.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def restore_recording_files(trash_meta, moved_entries)
    manifest = trash_meta['files'] || [
      { 'original_path' => trash_meta['original_path'], 'trash_path' => trash_meta['trash_path'] }
    ]
    return false if manifest.empty?

    valid = manifest.all? do |entry|
      trash_path = entry['trash_path']
      original_path = entry['original_path']
      trash_path_deletable?(trash_path) &&
        Storage::RecordingPaths.within_account?(original_path, account_id: @account.id) &&
        File.exist?(trash_path) && !File.exist?(original_path) && !File.symlink?(original_path)
    end
    return false unless valid

    manifest.each do |entry|
      FileUtils.mkdir_p(File.dirname(entry['original_path']))
      unless Storage::RecordingPaths.within_account?(entry['original_path'], account_id: @account.id)
        raise InvalidParams, I18n.t('storage_management.errors.invalid_path')
      end

      identity = move_file_exclusively(entry['trash_path'], entry['original_path'])
      moved_entries << entry.merge('restored_identity' => identity)
    end
    true
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  # Each rollback entry is independently guarded so one unsafe destination cannot prevent
  # restoring other files. The destination must still be absent and the source inode must
  # be the file this restore moved while the row/advisory locks remain held.
  def rollback_restored_recording_files(moved_entries)
    Array(moved_entries).reverse_each do |entry|
      begin
        original_path = entry['original_path']
        trash_path = entry['trash_path']
        next unless Storage::RecordingPaths.contained_in_account?(original_path, account_id: @account.id)
        next unless Storage::RecordingPaths.within_account?(
          trash_path, account_id: @account.id, include_trash: true
        )
        next if File.exist?(trash_path) || File.symlink?(trash_path)

        stat = File.stat(original_path)
        next unless [stat.dev, stat.ino] == entry['restored_identity']

        move_file_exclusively(original_path, trash_path)
      rescue StandardError => e
        Rails.logger.error(
          "[Storage::TrashService] Could not roll back restored recording for account #{@account.id}: #{e.class.name}"
        )
      end
    end
  end

  def trash_path_deletable?(path)
    path.present? && Storage::RecordingPaths.contained?(path, Storage::RecordingPaths.trash_root.join(@account.id.to_s, 'recordings'))
  end

  def mark_recording_purged(session)
    session.metadata['recording'] ||= {}
    session.metadata['recording']['purged'] = true
    session.metadata['recording']['purged_at'] = Time.current.iso8601
    %w[storage_key recording_ref recording_url].each { |key| session.metadata['recording'].delete(key) }
    retained = session.metadata.dig('recording', 'retained_original')
    retained['purged_at'] = Time.current.iso8601 if retained.is_a?(Hash) && retained['purged_at'].blank?
    session.recording_ref = nil
  end

  # Runs the block with the call session whose retained original is in the trash, under the recording lock and
  # the row lock. The block gets the session, the metadata copy to save and the retained_original hash and
  # returns the byte size it handled, or nil when it did nothing.
  def with_trashed_original(session_id)
    session = Telephony::CallSession.find_by(id: session_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless session

    expected_key = session.metadata.to_h.dig('recording', 'retained_original', 'storage_key').to_s
    bytes = nil
    Storage::RecordingLock.synchronize(account_id: @account.id, storage_keys: [expected_key]) do
      session.with_lock do
        session.reload
        metadata = (session.metadata || {}).deep_dup
        retained = metadata.dig('recording', 'retained_original')
        next unless retained.is_a?(Hash) && retained['trash'].is_a?(Hash) && retained['storage_key'].to_s == expected_key

        bytes = yield(session, metadata, retained)
      end
    end
    { count: bytes.nil? ? 0 : 1, bytes: bytes.to_i }
  end

  # The file goes back to where the retention job took it from; the call keeps playing the compressed recording.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def restore_original_recording(session_id)
    with_trashed_original(session_id) do |session, metadata, retained|
      trash = retained['trash']
      trash_path = trash['trash_path'].to_s
      original_path = trash['original_path'].to_s
      next unless trash_path_deletable?(trash_path) && File.file?(trash_path)
      next unless Storage::RecordingPaths.within_account?(original_path, account_id: @account.id)
      next if File.exist?(original_path) || File.symlink?(original_path)

      FileUtils.mkdir_p(File.dirname(original_path))
      move_file_exclusively(trash_path, original_path)
      begin
        retained.delete('trash')
        retained.delete('expires_at')
        retained['restored_at'] = Time.current.iso8601
        session.metadata = metadata
        session.save!(validate: false)
      rescue StandardError
        move_file_exclusively(original_path, trash_path) if File.exist?(original_path) && !File.exist?(trash_path)
        raise
      end
      trash['bytes'].to_i
    end
  end

  def purge_original_recording(session_id)
    with_trashed_original(session_id) do |session, metadata, retained|
      trash = retained['trash']
      path = trash['trash_path'].to_s
      if path.present? && File.exist?(path)
        raise InvalidParams, I18n.t('storage_management.errors.trash_path_rejected') unless trash_path_deletable?(path)

        File.delete(path)
      end

      retained.delete('trash')
      retained['purged_at'] = Time.current.iso8601
      retained['status'] = 'purged'
      session.metadata = metadata
      session.save!(validate: false)
      trash['bytes'].to_i
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

  def restore_all_originals
    count = 0
    bytes = 0
    trashed_original_sessions.find_each do |session|
      res = restore_original_recording(session.id)
      count += res[:count]
      bytes += res[:bytes]
    end
    { count: count, bytes: bytes }
  end

  def purge_all_originals
    count = 0
    bytes = 0
    trashed_original_sessions.find_each do |session|
      res = purge_original_recording(session.id)
      count += res[:count]
      bytes += res[:bytes]
    end
    { count: count, bytes: bytes }
  end

  # Fresh account and trash checks stay adjacent to the attachment state change.
  def restore_single_attachment(attachment_id)
    attachment = Attachment.find_by(id: attachment_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless attachment&.meta&.dig('trash')

    bytes = 0
    restored = false
    attachment.with_lock do
      attachment.reload
      next unless attachment.account_id == @account.id && attachment.meta.to_h['trash'].is_a?(Hash)

      bytes = attachment.meta.dig('trash', 'bytes').to_i
      attachment.meta = (attachment.meta || {}).deep_dup
      attachment.meta.delete('trash')
      attachment.save!(validate: false)
      restored = true
    end
    { count: restored ? 1 : 0, bytes: restored ? bytes : 0 }
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

  # Manifest, live-reference guard, physical deletion and JSON patch share one row lock.
  def purge_single_recording(session_id)
    session = Telephony::CallSession.find_by(id: session_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless session

    expected_keys = trash_storage_keys(session)
    purged_bytes = 0
    purged = false
    Storage::RecordingLock.synchronize(account_id: @account.id, storage_keys: expected_keys) do
      session.with_lock do
        session.reload
        trash_meta = session.metadata.to_h['trash']
        next unless trash_meta.is_a?(Hash)
        next unless trash_storage_keys(session) == expected_keys

        manifest = trash_meta['files'] || [
          { 'storage_key' => trash_meta['original_recording_ref'], 'trash_path' => trash_meta['trash_path'] }
        ]
        next unless purge_recording_references_safe?(session, manifest)

        manifest.each do |entry|
          path = entry['trash_path']
          next unless path.present? && File.exist?(path)
          raise InvalidParams, I18n.t('storage_management.errors.trash_path_rejected') unless trash_path_deletable?(path)

          File.delete(path)
        end

        purged_bytes = trash_meta['bytes'].to_i
        session.metadata = (session.metadata || {}).deep_dup
        session.metadata.delete('trash')
        mark_recording_purged(session)
        session.save!(validate: false)
        purged = true
      end
    end
    { count: purged ? 1 : 0, bytes: purged ? purged_bytes : 0 }
  end
  # Every same-account reference holder is checked before irreversible trash deletion.
  def purge_recording_references_safe?(session, manifest)
    return false if session.recording_ref.present?

    paths = manifest.flat_map { |entry| [entry['original_path'], entry['trash_path']] }.compact_blank.uniq
    refs = manifest.flat_map do |entry|
      entry_paths = [entry['original_path'], entry['trash_path']].compact_blank
      aliases = entry_paths.flat_map do |path|
        Storage::RecordingPaths.reference_aliases(
          path, account_id: @account.id, allow_missing: !File.exist?(path)
        )
      end
      storage_key = entry['storage_key'].to_s
      aliases + [storage_key, File.basename(storage_key)]
    end.compact_blank.uniq
    return true if refs.empty?

    other_sessions = Telephony::CallSession.where(account_id: @account.id).where.not(id: session.id)
    call_reference = call_session_recording_references(other_sessions, refs).find_each.any? do |candidate|
      values = call_session_recording_values(candidate)
      values.any? do |reference|
        recording_reference_matches_paths?(
          reference, refs, paths, qualified_references: values, conservative: true
        )
      end
    end
    message_reference = message_recording_references(refs).find_each.any? do |message|
      values = message_recording_values(message)
      values.any? do |reference|
        recording_reference_matches_paths?(
          reference, refs, paths, qualified_references: values, conservative: true
        )
      end
    end
    conversation_reference = conversation_recording_references(refs).find_each.any? do |conversation|
      values = conversation_recording_values(conversation)
      values.any? do |reference|
        recording_reference_matches_paths?(
          reference, refs, paths, qualified_references: values, conservative: true
        )
      end
    end
    !call_reference && !message_reference && !conversation_reference
  end

  def purge_single_attachment(attachment_id)
    attachment = Attachment.find_by(id: attachment_id, account_id: @account.id)
    return { count: 0, bytes: 0 } unless attachment

    bytes = 0
    purged = false
    attachment.with_lock do
      attachment.reload
      next unless attachment.account_id == @account.id && attachment.meta.to_h['trash'].is_a?(Hash)

      bytes = trashed_attachment_bytes(attachment)
      # Only the file goes. Voice-message transcripts and recognised document text live in attachment.meta and are
      # kept forever, so the row stays and is marked instead of being destroyed.
      attachment.file.purge if attachment.file.attached?
      attachment.meta = attachment.meta.to_h.deep_dup.except('trash').merge('file_purged_at' => Time.current.iso8601)
      attachment.save!(validate: false)
      purged = true
    end
    { count: purged ? 1 : 0, bytes: purged ? bytes : 0 }
  end

  def trashed_attachment_bytes(attachment)
    bytes = attachment.meta.dig('trash', 'bytes').to_i
    return bytes if bytes.positive? || !attachment.file.attached?

    attachment.file.byte_size.to_i
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

  def resolve_recording_path(session)
    Storage::RecordingPaths.resolve(session.recording_ref, account_id: session.account_id)
  end
end
# rubocop:enable Metrics/ClassLength
