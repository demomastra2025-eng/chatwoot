# Display names written into the task catalogs (types, outcomes, statuses) when
# an account is provisioned. They are neutral and follow the account language;
# the owner rule keeps the word "Touch" away from every user-visible text.
# The dashboard shows the same wording by code (CRM.TASKS.ACTIVITY_TYPE /
# OUTCOME / STATUS_NAMES) as long as the stored name is still a seeded one.
module Crm::TaskCatalogs::SeedNames
  SUPPORTED_LOCALES = %w[ru en kk].freeze
  FALLBACK_LOCALE = 'en'.freeze

  # English names the first release wrote into the database (migration
  # 20261004120000 and the first provisioner). Rows that still carry one of
  # them are renamed by Crm::TaskCatalogs::NameRepair.
  LEGACY_TYPE_NAMES = {
    'task' => 'Task',
    'call' => 'Call',
    'meeting' => 'Meeting',
    'message' => 'Message',
    'touch' => 'Touch'
  }.freeze
  LEGACY_STATUS_NAMES = {
    'todo' => 'To do',
    'in_progress' => 'In progress',
    'done' => 'Done',
    'cancelled' => 'Cancelled'
  }.freeze

  module_function

  def locale_for(account_locale)
    language = account_locale.to_s.split(/[-_]/).first
    SUPPORTED_LOCALES.include?(language) ? language : FALLBACK_LOCALE
  end

  def type_name(code, locale)
    translate("types.#{code}", locale)
  end

  def outcome_name(code, locale)
    translate("outcomes.#{code}", locale)
  end

  def status_name(code, locale)
    translate("statuses.#{code}", locale)
  end

  # The old English outcome names were the humanized codes.
  def legacy_outcome_name(code)
    code.to_s.humanize
  end

  # Every rename the repair has to apply for an account language: the legacy
  # English name of a system code and the neutral name it becomes. Pairs that
  # are already equal are skipped.
  def renames(locale)
    type_renames(locale) + outcome_renames(locale) + status_renames(locale)
  end

  def type_renames(locale)
    LEGACY_TYPE_NAMES.filter_map do |code, from|
      to = type_name(code, locale)
      { kind: :type, code: code, from: from, to: to } unless from == to
    end
  end

  def outcome_renames(locale)
    Crm::TaskCatalogs::Provisioner::TASK_OUTCOMES.flat_map do |type_code, outcome_codes|
      outcome_codes.filter_map do |code|
        from = legacy_outcome_name(code)
        to = outcome_name(code, locale)
        { kind: :outcome, type_code: type_code, code: code, from: from, to: to } unless from == to
      end
    end
  end

  def status_renames(locale)
    LEGACY_STATUS_NAMES.filter_map do |code, from|
      to = status_name(code, locale)
      { kind: :status, code: code, from: from, to: to } unless from == to
    end
  end

  def translate(key, locale)
    full_key = "crm.task_catalogs.#{key}"
    I18n.t(full_key, locale: locale, default: I18n.t(full_key, locale: FALLBACK_LOCALE))
  end
end
