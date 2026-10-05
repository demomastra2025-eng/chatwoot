class Crm::TaskCatalogs::Provisioner
  # Display names are not part of the definitions: they follow the account
  # language (see Crm::TaskCatalogs::SeedNames).
  TASK_STATUS_DEFINITIONS = [
    { code: 'todo', category: 'open', default: true },
    { code: 'in_progress', category: 'in_progress', default: false },
    { code: 'done', category: 'done', default: false },
    { code: 'cancelled', category: 'cancelled', default: false }
  ].freeze
  TASK_TYPE_DEFINITIONS = [
    { code: 'task', icon: 'i-lucide-list-todo', default: true },
    { code: 'call', icon: 'i-lucide-phone' },
    { code: 'meeting', icon: 'i-lucide-users' },
    { code: 'message', icon: 'i-lucide-message-square' },
    { code: 'touch', icon: 'i-lucide-handshake' }
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
    return if catalog_current?

    ApplicationRecord.transaction do
      acquire_catalog_lock!
      next if catalog_current?

      ensure_default_task_statuses
      ensure_default_task_catalogs
      localize_seeded_names
    end
  end

  private

  attr_reader :account

  def acquire_catalog_lock!
    identity = "crm-task-catalog:v1:#{account.id}"
    lock_id = Digest::SHA256.digest(identity).unpack1('q>').to_i
    lock_sql = ApplicationRecord.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?)', lock_id])
    ApplicationRecord.connection.execute(lock_sql)
  end

  def catalog_current?
    task_statuses_current? && task_catalogs_current?
  end

  def locale
    @locale ||= Crm::TaskCatalogs::SeedNames.locale_for(account.locale)
  end

  # Rows created by the first release carry English names (including the
  # banned "Touch"); the repair renames only those that are still unedited.
  def localize_seeded_names
    Crm::TaskCatalogs::NameRepair.new(accounts: Account.where(id: account.id)).perform
  end

  def legacy_names
    @legacy_names ||= Crm::TaskCatalogs::SeedNames.renames(locale)
                                                  .group_by { |rename| rename[:kind] }
                                                  .transform_values { |renames| renames.index_by { |rename| rename.values_at(:type_code, :code) } }
  end

  def legacy_name?(kind, code, name, type_code: nil)
    rename = legacy_names.dig(kind, [type_code, code])
    rename.present? && rename[:from] == name
  end

  def task_statuses_current?
    expected_status_codes = TASK_STATUS_DEFINITIONS.map { |definition| definition.fetch(:code) }
    statuses = account.crm_task_statuses.where(code: expected_status_codes).pluck(:code, :name)
    return false unless statuses.size == TASK_STATUS_DEFINITIONS.size

    statuses.none? { |code, name| legacy_name?(:status, code, name) }
  end

  def task_catalogs_current?
    type_codes = TASK_TYPE_DEFINITIONS.map { |definition| definition.fetch(:code) }
    task_types = account.crm_task_types.includes(:outcomes).where(code: type_codes).to_a
    return false unless task_types.size == TASK_TYPE_DEFINITIONS.size

    task_types.all? { |task_type| task_type_current?(task_type) }
  end

  def task_type_current?(task_type)
    return false unless (TASK_OUTCOMES.fetch(task_type.code) - task_type.outcomes.map(&:code)).empty?
    return false if legacy_name?(:type, task_type.code, task_type.name)

    task_type.outcomes.none? do |outcome|
      legacy_name?(:outcome, outcome.code, outcome.name, type_code: task_type.code)
    end
  end

  def ensure_default_task_statuses
    TASK_STATUS_DEFINITIONS.each_with_index do |definition, index|
      status = account.crm_task_statuses.find_or_initialize_by(code: definition[:code])
      next unless status.new_record?

      status.assign_attributes(
        definition.merge(
          name: Crm::TaskCatalogs::SeedNames.status_name(definition[:code], locale),
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
        task_type.assign_attributes(
          definition.merge(
            name: Crm::TaskCatalogs::SeedNames.type_name(definition[:code], locale),
            position: index + 1,
            active: true
          )
        )
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
        name: Crm::TaskCatalogs::SeedNames.outcome_name(code, locale),
        position: index + 1,
        active: true,
        default: index.zero?,
        requires_note: %w[not_done other].include?(code)
      )
      outcome.save!
    end
  end
end
