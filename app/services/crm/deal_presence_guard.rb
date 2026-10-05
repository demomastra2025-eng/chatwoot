# A pipeline or a stage that still holds deals cannot be deleted: the deals have
# to be moved to another pipeline or stage first (the HubSpot rule). Archived
# deals count because they still reference the pipeline and the stage.
class Crm::DealPresenceGuard
  RULES = {
    'Crm::Pipeline' => {
      code: 'PIPELINE_HAS_DEALS',
      message: 'В воронке есть сделки (%<count>d): перенесите их в другую воронку или удалите их, затем удалите воронку.'
    },
    'Crm::Stage' => {
      code: 'STAGE_HAS_DEALS',
      message: 'В этапе есть сделки (%<count>d): перенесите их в другой этап или в другую воронку, затем удалите этап.'
    }
  }.freeze

  def self.ensure_empty!(record, note: nil)
    new(record).ensure_empty!(note: note)
  end

  def initialize(record)
    @record = record
  end

  def ensure_empty!(note: nil)
    count = record.deals.count
    return if count.zero?

    raise ::Crm::Error.new(
      code: rule[:code],
      message: [format(rule[:message], count: count), archived_note(archived_count), note].compact.join(' '),
      status: :unprocessable_content,
      details: details(count, archived_count)
    )
  end

  private

  attr_reader :record

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
