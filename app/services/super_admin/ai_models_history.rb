# frozen_string_literal: true

# What a setting of the «Модели ИИ» page was before it was last changed here, from the audit log of the settings saves
# (SuperAdmin::AppConfigSaver writes one entry for every change): «Было: GPT-5.6 Luna, изменил Айдар 18.10.2026 14:20».
#
#   history = SuperAdmin::AiModelsHistory.new(values: { 'CAPTAIN_DEFAULT_MODEL' => 'openai/gpt-6-luna' })
#   history.previous('CAPTAIN_DEFAULT_MODEL') # => Entry(value: 'openai/gpt-5.6-luna', actor: 'Айдар', at: <Time>) or nil
#
# An entry is offered only when it explains the value that is stored now: if the setting was changed by other means
# since (the console of a developer), the audit does not know what was before and nothing is offered. The value of a
# secret is never in the log, so a secret has no entry.
class SuperAdmin::AiModelsHistory
  # value: what the setting was ('' when it followed the built-in value); actor: the name of the super admin or nil
  Entry = Struct.new(:value, :actor, :at, keyword_init: true)

  RECENT_ENTRIES = 50

  # values: name => the stored value of the settings of the page
  def initialize(values:)
    @values = values.to_h
    @entries = nil
  end

  def previous(key)
    return if SuperAdmin::InstallationConfigs.secret?(key)

    entries[key]
  end

  private

  def entries
    @entries ||= load_entries
  end

  def load_entries
    ids = InstallationConfig.where(name: @values.keys).pluck(:name, :id).to_h
    return {} if ids.empty?

    names = ids.invert
    audits = Audited::Audit.where(auditable_type: 'InstallationConfig', auditable_id: ids.values, action: SuperAdmin::AppConfigSaver::AUDIT_ACTION)
                           .order(created_at: :desc, id: :desc).limit(RECENT_ENTRIES * ids.size).includes(:user)
    audits.group_by(&:auditable_id).filter_map do |config_id, list|
      key = names[config_id]
      entry = entry_for(key, list.first)
      [key, entry] if entry
    end.to_h
  rescue StandardError => e
    Rails.logger.warn("[SuperAdmin::AiModelsHistory] #{e.class}: #{e.message}")
    {}
  end

  def entry_for(key, audit)
    old_text, new_text = Array(audit.audited_changes.to_h['value'])
    return unless explains_current?(key, new_text)
    return if old_text.nil? || truncated?(old_text)

    Entry.new(value: old_text.to_s, actor: actor_name(audit), at: audit.created_at)
  end

  # The log keeps a cut text («...» at its end) of a long value; what is cut cannot be put back
  def truncated?(text)
    text.to_s.end_with?('...') && text.to_s.length >= SuperAdmin::AppConfigSaver::VALUE_LIMIT
  end

  def explains_current?(key, new_text)
    limit = SuperAdmin::AppConfigSaver.value_limit(key)
    SuperAdmin::InstallationConfigs.printable(@values[key]).truncate(limit) == new_text.to_s
  end

  def actor_name(audit)
    user = audit.user
    return audit.username.presence if user.blank?

    user.try(:name).presence || user.try(:email)
  end
end
