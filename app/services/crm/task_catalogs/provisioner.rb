class Crm::TaskCatalogs::Provisioner
  TASK_STATUS_DEFINITIONS = [
    { code: 'todo', name: 'To do', category: 'open', default: true },
    { code: 'in_progress', name: 'In progress', category: 'in_progress', default: false },
    { code: 'done', name: 'Done', category: 'done', default: false },
    { code: 'cancelled', name: 'Cancelled', category: 'cancelled', default: false }
  ].freeze
  TASK_TYPE_DEFINITIONS = [
    { code: 'task', name: 'Task', icon: 'i-lucide-list-todo', default: true },
    { code: 'call', name: 'Call', icon: 'i-lucide-phone' },
    { code: 'meeting', name: 'Meeting', icon: 'i-lucide-users' },
    { code: 'message', name: 'Message', icon: 'i-lucide-message-square' },
    { code: 'touch', name: 'Touch', icon: 'i-lucide-handshake' }
  ].freeze
  TASK_OUTCOMES = {
    'task' => %w[completed not_done cancelled other],
    'call' => %w[answered no_answer busy cancelled not_done other],
    'meeting' => %w[held cancelled no_show rescheduled not_done other],
    'message' => %w[sent failed not_done other],
    'touch' => %w[completed no_answer cancelled not_done other]
  }.freeze

  def initialize(account:)
    @account = account
  end

  def perform
    return if catalog_complete?

    ApplicationRecord.transaction do
      acquire_catalog_lock!
      next if catalog_complete?

      ensure_default_task_statuses
      ensure_default_task_catalogs
    end
  end

  private

  attr_reader :account

  def acquire_catalog_lock!
    identity = "crm-task-catalog:v1:#{account.id}"
    lock_id = Digest::SHA256.digest(identity).unpack1('q>')
    ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{lock_id})")
  end

  def catalog_complete?
    task_statuses_complete? && task_catalogs_complete?
  end

  def task_statuses_complete?
    expected_status_codes = TASK_STATUS_DEFINITIONS.map { |definition| definition.fetch(:code) }
    status_codes = account.crm_task_statuses.where(code: expected_status_codes).pluck(:code)
    status_codes.size == TASK_STATUS_DEFINITIONS.size
  end

  def task_catalogs_complete?
    type_codes = TASK_TYPE_DEFINITIONS.map { |definition| definition.fetch(:code) }
    task_types = account.crm_task_types.includes(:outcomes).where(code: type_codes).to_a
    return false unless task_types.size == TASK_TYPE_DEFINITIONS.size

    task_types.all? do |task_type|
      (TASK_OUTCOMES.fetch(task_type.code) - task_type.outcomes.map(&:code)).empty?
    end
  end

  def ensure_default_task_statuses
    TASK_STATUS_DEFINITIONS.each_with_index do |definition, index|
      status = account.crm_task_statuses.find_or_initialize_by(code: definition[:code])
      next unless status.new_record?

      status.assign_attributes(
        definition.merge(
          color: Crm::TaskStatus::STANDARD_COLORS[index] || Crm::TaskStatus::DEFAULT_COLOR,
          position: index + 1,
          active: true
        )
      )
      status.save!
    end
  end

  def ensure_default_task_catalogs
    TASK_TYPE_DEFINITIONS.each_with_index do |definition, index|
      task_type = account.crm_task_types.find_or_initialize_by(code: definition[:code])
      if task_type.new_record?
        task_type.assign_attributes(definition.merge(position: index + 1, active: true))
        task_type.save!
      end
      ensure_default_task_outcomes(task_type)
    end
  end

  def ensure_default_task_outcomes(task_type)
    TASK_OUTCOMES.fetch(task_type.code).each_with_index do |code, index|
      outcome = task_type.outcomes.find_or_initialize_by(code: code)
      next unless outcome.new_record?

      outcome.assign_attributes(
        account: account,
        name: code.humanize,
        position: index + 1,
        active: true,
        default: index.zero?,
        requires_note: %w[not_done other].include?(code)
      )
      outcome.save!
    end
  end
end
