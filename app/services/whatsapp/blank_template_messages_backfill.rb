# frozen_string_literal: true

class Whatsapp::BlankTemplateMessagesBackfill
  def initialize(apply: false, backup_file: nil, restore_file: nil, account_id: nil)
    @apply = apply
    @backup_file = backup_file.presence || default_backup_file
    @restore_file = restore_file.presence
    @account_id = account_id.presence&.to_i
    @inboxes_by_id = {}
    @stats_by_account = Hash.new do |h, k|
      h[k] = { total: 0, matched: 0, with_buttons: 0, updated: 0, unmatched: 0 }
    end
  end

  def perform
    return perform_restore if @restore_file

    backup_entries = collect_candidates
    apply_updates(backup_entries) if @apply && backup_entries.any?
    build_summary
  end

  private

  def perform_restore
    raise ArgumentError, "RESTORE_FILE not found: #{@restore_file}" unless File.exist?(@restore_file)
    raise ArgumentError, 'Pass APPLY=1 to execute restore' unless @apply

    rows = JSON.parse(File.read(@restore_file))
    restored = rows.count { |entry| restore_entry(entry) }
    { mode: 'restore', restored: restored, total_in_backup: rows.size }
  end

  def restore_entry(entry)
    msg = Message.find_by(id: entry.fetch('id'))
    return false unless msg

    # Bypass callbacks/webhooks when restoring historical message columns.
    # rubocop:disable Rails/SkipsModelValidations
    msg.update_columns(
      content: entry['previous_content'],
      additional_attributes: entry['previous_additional_attributes']
    )
    # rubocop:enable Rails/SkipsModelValidations
    true
  end

  def candidate_scope
    scope = Message.where(message_type: Message.message_types[:outgoing])
                   .where("COALESCE(content, '') = ''")
                   .where("additional_attributes::jsonb ? 'template_params'")
    @account_id ? scope.where(account_id: @account_id) : scope
  end

  def collect_candidates
    entries = []
    candidate_scope.find_each do |msg|
      record_candidate(msg, entries)
    end
    entries
  end

  def record_candidate(msg, entries)
    acct_stats = @stats_by_account[msg.account_id]
    acct_stats[:total] += 1

    rendered_text, rendered_buttons = render_for_message(msg)
    if rendered_text.blank?
      acct_stats[:unmatched] += 1
      return
    end

    acct_stats[:matched] += 1
    acct_stats[:with_buttons] += 1 if rendered_buttons.present?
    return unless @apply

    entries << build_backup_entry(msg, rendered_text, rendered_buttons)
  end

  def build_backup_entry(msg, rendered_text, rendered_buttons)
    {
      'id' => msg.id,
      'account_id' => msg.account_id,
      'conversation_id' => msg.conversation_id,
      'previous_content' => msg.content,
      'previous_additional_attributes' => msg.additional_attributes.to_h.deep_dup,
      'rendered_text' => rendered_text,
      'rendered_buttons' => rendered_buttons
    }
  end

  def apply_updates(backup_entries)
    persisted_backup = backup_entries.map { |e| e.except('rendered_text', 'rendered_buttons') }
    FileUtils.mkdir_p(File.dirname(@backup_file))
    File.write(@backup_file, JSON.pretty_generate(persisted_backup))

    backup_entries.each { |entry| update_message_from_entry(entry) }
  end

  def update_message_from_entry(entry)
    msg = Message.find_by(id: entry['id'])
    return unless msg

    next_additional = msg.additional_attributes.to_h.deep_dup
    next_additional['template_buttons'] = entry['rendered_buttons'] if entry['rendered_buttons'].present?

    # Bypass callbacks/webhooks/ActionCable when backfilling historical message text.
    # rubocop:disable Rails/SkipsModelValidations
    msg.update_columns(
      content: entry['rendered_text'],
      additional_attributes: next_additional
    )
    # rubocop:enable Rails/SkipsModelValidations
    @stats_by_account[msg.account_id][:updated] += 1
  end

  def render_for_message(msg)
    inbox = (@inboxes_by_id[msg.inbox_id] ||= Inbox.includes(:channel).find_by(id: msg.inbox_id))
    renderer = Whatsapp::TemplateMessageRenderer.new(
      channel: inbox&.channel,
      template_params: msg.additional_attributes.to_h['template_params']
    )
    [renderer.render_text, renderer.render_buttons]
  end

  def build_summary
    {
      mode: @apply ? 'apply' : 'dry_run',
      backup_file: @apply ? @backup_file : nil,
      totals: aggregate_totals,
      by_account: @stats_by_account
    }
  end

  def aggregate_totals
    values = @stats_by_account.values
    %i[total matched with_buttons updated unmatched].index_with { |key| values.sum { |s| s[key] } }
  end

  def default_backup_file
    Rails.root.join(
      'storage',
      'onelink_backups',
      "wa-blank-template-messages-#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}.json"
    ).to_s
  end
end
