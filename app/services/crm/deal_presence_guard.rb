# A pipeline or a stage that still holds deals cannot be deleted: the deals have
# to be moved to another pipeline or stage first (the HubSpot rule). Archived
# deals count because they still reference the pipeline and the stage.
#
# Once the deals are gone the stage history (crm_stage_visits) must not block the deletion forever, so it is kept with
# its name snapshots and only loses the link. That needs pipeline_id and stage_id to accept NULL; on a database where
# they are still NOT NULL the guard answers with the *_HAS_HISTORY error instead of letting the database raise.
class Crm::DealPresenceGuard
  RULES = {
    'Crm::Pipeline' => {
      code: 'PIPELINE_HAS_DEALS',
      message: 'В воронке есть сделки (%<count>d): перенесите их в другую воронку или удалите их, затем удалите воронку.',
      history_code: 'PIPELINE_HAS_HISTORY',
      history_message: 'Воронку нельзя удалить: через неё проходили сделки. Отключите воронку, чтобы сохранить историю сделок.'
    },
    'Crm::Stage' => {
      code: 'STAGE_HAS_DEALS',
      message: 'В этапе есть сделки (%<count>d): перенесите их в другой этап или в другую воронку, затем удалите этап.',
      history_code: 'STAGE_HAS_HISTORY',
      history_message: 'Этап нельзя удалить: через него проходили сделки. Отключите этап, чтобы сохранить историю сделок.'
    }
  }.freeze

  def self.ensure_empty!(record, note: nil)
    new(record).ensure_empty!(note: note)
  end

  def self.history_blocked?(record)
    new(record).history_blocked?
  end

  def initialize(record)
    @record = record
  end

  def ensure_empty!(note: nil)
    count = record.deals.count
    return ensure_history_detachable!(note) if count.zero?

    raise ::Crm::Error.new(
      code: rule[:code],
      message: [format(rule[:message], count: count), archived_note(archived_count), note].compact.join(' '),
      status: :unprocessable_content,
      details: details(count, archived_count)
    )
  end

  def history_blocked?
    !::Crm::StageVisit.references_detachable? && record.stage_visits.exists?
  end

  private

  attr_reader :record

  def ensure_history_detachable!(note)
    return unless history_blocked?

    raise ::Crm::Error.new(
      code: rule[:history_code],
      message: [rule[:history_message], note].compact.join(' '),
      status: :unprocessable_content
    )
  end

  def rule
    RULES.fetch(record.class.name)
  end

  def archived_count
    @archived_count ||= record.deals.archived.count
  end

  def archived_note(count)
    "Из них в архиве: #{count}." if count.positive?
  end

  def details(count, archived)
    { deal_count: count, archived_deal_count: archived }.tap do |payload|
      payload[:stage_id] = record.id if record.is_a?(::Crm::Stage)
    end
  end
end
