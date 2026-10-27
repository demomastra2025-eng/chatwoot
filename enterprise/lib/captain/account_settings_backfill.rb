# frozen_string_literal: true

class Captain::AccountSettingsBackfill
  # The agent whose settings seed the workspace settings of an account that has none yet: the most recently changed enabled agent.
  # There is no main agent; the settings are one set for every agent of the workspace.
  def self.reference_assistant(account)
    account.captain_assistants.external_agent.where(active: true).order(updated_at: :desc, id: :desc).first
  end

  def self.backfill!(account)
    account.with_lock do
      account.reload
      return false if account.settings.to_h.key?(Captain::AccountSettings::KEY)

      assistant = reference_assistant(account)
      settings = Captain::AccountSettings.new(account)
      values = assistant ? Captain::AccountSettings.from_assistant(assistant) : settings.defaults(include_availability: false)
      account.update!(settings: account.settings.to_h.merge(Captain::AccountSettings::KEY => values))
      true
    end
  end

  # Account settings that were saved while an AI-mode message still kept the owner's wishes in `text` (the old per-agent
  # "Пожелания к сообщению"): `text` is now the sentence a customer gets when the notice model fails, so the wishes move to
  # `instruction` and `text` is cleared. Idempotent; returns the names of the messages moved (nothing is written on a dry run).
  def self.move_message_guidance!(account, dry_run: false)
    account.with_lock do
      account.reload
      settings = Captain::AccountSettings.new(account)
      patch = message_guidance_patch(settings.section('handoff'))
      settings.update!('handoff' => patch) if patch.any? && !dry_run
      patch.keys
    end
  end

  def self.message_guidance_patch(handoff)
    Captain::AccountSettings::MESSAGE_FIELDS.each_with_object({}) do |key, patch|
      message = handoff.fetch(key).to_h
      next unless message['mode'] == 'generated' && message['text'].to_s.strip.present? && message['instruction'].to_s.strip.blank?

      patch[key] = { 'text' => '',
                     'instruction' => message['text'].to_s.squish.first(Captain::AccountSettings::MESSAGE_INSTRUCTION_MAX_LENGTH) }
    end
  end
  private_class_method :message_guidance_patch

  def self.conflicts(account)
    source = reference_assistant(account)
    return [] unless source

    reference = Captain::AccountSettings.from_assistant(source)
    account.captain_assistants.external_agent.where.not(id: source.id).order(:id).filter_map do |assistant|
      other = Captain::AccountSettings.from_assistant(assistant)
      names = reference.flat_map do |section, fields|
        fields.keys.filter_map { |key| "#{section}.#{key}" unless fields[key] == other.dig(section, key) }
      end
      { account_id: account.id, reference_agent_id: source.id, agent_id: assistant.id, settings: names } if names.any?
    end
  end
end
