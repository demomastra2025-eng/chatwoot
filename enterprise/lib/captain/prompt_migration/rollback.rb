# frozen_string_literal: true

require 'digest'

# Rolls one prompt migration back: every agent whose config['prompt_history'] holds an entry of that migration gets the texts of
# that entry again, and the entry is removed. The same dry-run and confirm flow as the migration (see Plan and Applier).
class Captain::PromptMigration::Rollback
  attr_reader :migration, :entries

  def initialize(migration:, account_ids: [])
    @migration = migration.to_s
    scope = Captain::Assistant.where("config -> 'prompt_history' @> ?", [{ migration: @migration }].to_json)
    scope = scope.where(account_id: Array(account_ids).map(&:to_i)) if Array(account_ids).any?
    @entries = scope.order(:account_id, :id).map { |assistant| entry_for(assistant) }
  end

  def digest
    payload = @entries.map { |entry| [entry.assistant_id, entry.current_digest, entry.proposed[:description], entry.proposed[:routing_description]] }
    Digest::SHA256.hexdigest(JSON.generate(['rollback', @migration, payload]))[0, 16]
  end

  def apply!(confirm:)
    raise Captain::PromptMigration::Applier::ConfirmationError, "CONFIRM must be #{digest}" unless confirm.to_s == digest

    @entries.select { |entry| restore(entry) }.map(&:assistant_id)
  end

  private

  def entry_for(assistant)
    saved = Array(assistant.config.to_h[Captain::PromptMigration::Applier::HISTORY_KEY]).reverse.find { |item| item['migration'] == @migration }
    current = { description: assistant.description.to_s, routing_description: assistant.routing_description.to_s }
    Captain::PromptMigration::Plan::Entry.new(
      account_id: assistant.account_id, assistant_id: assistant.id, name: assistant.name, status: 'ok', current: current,
      proposed: { description: saved['description'].to_s, routing_description: saved['routing_description'].to_s },
      current_digest: Captain::PromptMigration::Plan.digest_of(current[:description], current[:routing_description]), findings: [], notes: []
    )
  end

  def restore(entry)
    Captain::Assistant.transaction do
      assistant = Captain::Assistant.lock.find_by(id: entry.assistant_id, account_id: entry.account_id)
      next false unless assistant && stored_digest(assistant) == entry.current_digest

      history = Array(assistant.config.to_h[Captain::PromptMigration::Applier::HISTORY_KEY]).reject { |item| item['migration'] == @migration }
      assistant.update!(description: entry.proposed[:description], routing_description: entry.proposed[:routing_description],
                        config: assistant.config.to_h.merge(Captain::PromptMigration::Applier::HISTORY_KEY => history))
      true
    end
  rescue ActiveRecord::RecordInvalid
    false
  end

  def stored_digest(assistant)
    Captain::PromptMigration::Plan.digest_of(assistant.description.to_s, assistant.routing_description.to_s)
  end
end
