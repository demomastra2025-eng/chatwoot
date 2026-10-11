# frozen_string_literal: true

class Captain::AccountSettingsBackfill
  def self.main_assistant(account)
    assistants = account.captain_assistants.external_agent.where(active: true).order(updated_at: :desc, id: :desc).to_a
    return if assistants.empty?

    scores = conversation_scores(account, assistants)
    assistants.max_by { |assistant| [scores.fetch(assistant.id, 0), assistant.updated_at, assistant.id] }
  end

  def self.conversation_scores(account, assistants)
    inbox_ids = CaptainInbox.where(captain_assistant_id: assistants.map(&:id)).pluck(:inbox_id, :captain_assistant_id)
    counts = Conversation.where(account_id: account.id, inbox_id: inbox_ids.map(&:first))
                         .where(created_at: 30.days.ago..).group(:inbox_id).count
    inbox_ids.each_with_object(Hash.new(0)) do |(inbox_id, assistant_id), scores|
      scores[assistant_id] += counts.fetch(inbox_id, 0)
    end
  end

  def self.backfill!(account)
    account.with_lock do
      account.reload
      return false if account.settings.to_h.key?(Captain::AccountSettings::KEY)

      assistant = main_assistant(account)
      settings = Captain::AccountSettings.new(account)
      values = assistant ? Captain::AccountSettings.from_assistant(assistant) : settings.defaults.except('availability')
      account.update!(settings: account.settings.to_h.merge(Captain::AccountSettings::KEY => values))
      true
    end
  end

  def self.conflicts(account)
    main = main_assistant(account)
    return [] unless main

    reference = Captain::AccountSettings.from_assistant(main)
    account.captain_assistants.external_agent.where.not(id: main.id).order(:id).filter_map do |assistant|
      other = Captain::AccountSettings.from_assistant(assistant)
      names = reference.flat_map do |section, fields|
        fields.keys.filter_map { |key| "#{section}.#{key}" unless fields[key] == other.dig(section, key) }
      end
      { account_id: account.id, main_agent_id: main.id, agent_id: assistant.id, settings: names } if names.any?
    end
  end
end
