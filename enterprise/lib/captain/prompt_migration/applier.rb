# frozen_string_literal: true

# Writes a reviewed plan (see Plan), or rolls a migration back. Only with the digest of the reviewed dry run (CONFIRM): what was
# reviewed is what is written. Per agent, under a row lock: the stored text is checked again against the plan, the old texts go to
# config['prompt_history'] (the last HISTORY_LIMIT migrations), the new ones are saved. An agent whose text changed after the dry
# run is skipped (drift), never overwritten.
class Captain::PromptMigration::Applier
  HISTORY_KEY = 'prompt_history'
  HISTORY_LIMIT = 5

  class ConfirmationError < StandardError; end

  Outcome = Struct.new(:applied, :skipped, keyword_init: true)

  def initialize(plan, confirm:)
    @plan = plan
    raise ConfirmationError, "CONFIRM must be the digest of the reviewed dry run (#{plan.digest})" unless confirm.to_s == plan.digest
  end

  def apply!
    applied = []
    skipped = []
    @plan.applicable.each do |entry|
      write(entry) ? applied << entry.assistant_id : skipped << entry.assistant_id
    end
    Outcome.new(applied: applied, skipped: skipped)
  end

  private

  def write(entry)
    Captain::Assistant.transaction do
      assistant = Captain::Assistant.lock.find_by(id: entry.assistant_id, account_id: entry.account_id)
      next false unless assistant && digest(assistant) == entry.current_digest

      save(assistant, entry.proposed)
      Rails.logger.info("[CAPTAIN][PromptMigration] applied migration=#{@plan.migration} assistant_id=#{assistant.id}")
      true
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[CAPTAIN][PromptMigration] rejected assistant_id=#{entry.assistant_id} errors=#{e.record.errors.attribute_names.join(',')}")
    false
  end

  def save(assistant, proposed)
    assistant.update!(description: proposed[:description], routing_description: proposed[:routing_description],
                      config: assistant.config.to_h.merge(HISTORY_KEY => history_with(assistant)))
  end

  # The prompt history with the texts this migration replaces as its newest entry.
  def history_with(assistant)
    Array(assistant.config.to_h[HISTORY_KEY]).last(HISTORY_LIMIT - 1) +
      [{ 'migration' => @plan.migration, 'at' => Time.current.iso8601, 'description' => assistant.description.to_s,
         'routing_description' => assistant.routing_description.to_s }]
  end

  def digest(assistant)
    Captain::PromptMigration::Plan.digest_of(assistant.description.to_s, assistant.routing_description.to_s)
  end
end
