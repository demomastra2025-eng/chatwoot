# Retired inbox columns remain unchanged for application rollback. Activation
# copies only unambiguous values; divergent texts require an explicit common
# message through account settings. Nothing is sent by this service.
class Accounts::WorkspaceRepliesMigration
  class Conflict < StandardError; end

  def initialize(account)
    @account = account
  end

  def report
    rows = @account.inboxes.order(:id).pluck(:id, :channel_type, :greeting_enabled, :greeting_message, :out_of_office_message)
    candidates = candidate_configs(rows)
    {
      account_id: @account.id,
      digest: Digest::SHA256.hexdigest([rows, @account.workspace_greeting, @account.workspace_out_of_office].to_json),
      conflicts: candidates.filter_map { |key, candidate| key if candidate[:conflict] },
      configs: candidates.transform_values { |candidate| candidate[:config] }
    }
  end

  def apply!(expected_digest:, configs: nil)
    @account.with_lock do
      @account.inboxes.order(:id).lock.load
      snapshot = report
      raise Conflict, 'Workspace replies changed after inspection' unless snapshot[:digest] == expected_digest
      raise Conflict, "Conflicting legacy values: #{snapshot[:conflicts].join(', ')}" if configs.nil? && snapshot[:conflicts].any?

      selected = selected_configs(snapshot, configs)
      @account.update!(selected) if selected.any?
    end
  end

  private

  def selected_configs(snapshot, explicit)
    return snapshot[:configs] if explicit.nil?

    unless explicit.is_a?(Hash) && explicit.keys.map(&:to_s).sort == snapshot[:configs].keys.sort
      raise Conflict, 'Explicit choice must contain exactly the pending common reply settings'
    end

    explicit.deep_stringify_keys
  end

  def candidate_configs(rows)
    {}.tap do |candidates|
      candidates['workspace_greeting'] = greeting_candidate(rows) unless @account.workspace_greeting.is_a?(Hash)
      candidates['workspace_out_of_office'] = offline_candidate(rows) unless @account.workspace_out_of_office.is_a?(Hash)
    end
  end

  def greeting_candidate(rows)
    eligible = rows.reject { |row| AccountWorkspaceReplies::NON_TEXT_CHANNEL_TYPES.include?(row[1]) }
    active = active_greetings(eligible)
    messages = greeting_messages(eligible, active)
    {
      conflict: messages.size > 1,
      config: {
        'enabled' => active.any?, 'message' => messages.one? ? messages.first : '',
        'excluded_inbox_ids' => active.any? ? eligible.map(&:first) - active.map(&:first) : []
      }
    }
  end

  def active_greetings(eligible)
    eligible.select { |row| row[2] && row[3].present? }
  end

  def greeting_messages(eligible, active)
    (active.presence || eligible).filter_map { |row| row[3].presence }.uniq
  end

  def offline_candidate(rows)
    messages = rows.filter_map { |row| row[4].presence }.uniq
    { conflict: messages.size > 1, config: { 'enabled' => messages.any?, 'message' => messages.one? ? messages.first : '' } }
  end
end
