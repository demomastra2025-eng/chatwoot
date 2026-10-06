# frozen_string_literal: true

# The installation rows of the Luna 6 cut-over. A row is "present" with a value (a blank value counts as no value) or
# absent. What the cut-over does with a row depends on its mode:
#   :target             the row becomes Luna 6 and is created when absent: the platform default
#   :target_if_present  the same for a row that exists; an absent row stays absent
#   :follow_default     the row of a platform-managed slot (image recognition, label hints) is blanked, so the slot
#                       follows the platform default and the single default-model switch moves it as well
# The cut-over refuses a row that is in neither the snapshot state nor its after-state. A rollback restores a row that is
# still as the cut-over left it and leaves every other row alone: somebody changed it on purpose after the cut-over (the
# quick rollback in Super Admin is such a change), and that must not block the rollback of the account choices.
class Llm::CaptainLunaRollout::InstallationRows
  # rows: name => mode
  def initialize(rows:, target:)
    @rows = rows
    @target = target
  end

  def snapshot
    configs = InstallationConfig.where(name: rows.keys).index_by(&:name)
    rows.keys.map { |name| { name: name, was_present: configs.key?(name), before: configs[name]&.value } }
  end

  def lock
    InstallationConfig.where(name: rows.keys).order(:name).lock.index_by(&:name)
  end

  def verify!(entries, configs)
    entries.each do |entry|
      current = state(configs[entry[:name]])
      next if [before_state(entry), after_state(entry)].include?(current)

      raise Llm::CaptainLunaRollout::StalePlan, "#{entry[:name]} changed since the snapshot"
    end
  end

  def apply!(entries, configs)
    entries.each do |entry|
      present, value = after_state(entry)
      write!(entry[:name], configs[entry[:name]], present, value)
    end
  end

  # Returns the names of the rows that were left alone because they are in neither state.
  def restore!(entries, configs)
    entries.filter_map do |entry|
      config = configs[entry[:name]]
      next entry[:name] unless [before_state(entry), after_state(entry)].include?(state(config))

      write!(entry[:name], config, entry[:was_present], entry[:before])
      nil
    end
  end

  # The rows that differ from the snapshot now, as text lines; empty when all is as before.
  def differences(entries)
    configs = InstallationConfig.where(name: rows.keys).index_by(&:name)
    entries.filter_map do |entry|
      current = state(configs[entry[:name]])
      next if current == before_state(entry)

      "#{entry[:name]}: #{describe(current)}, the snapshot had #{describe(before_state(entry))}"
    end
  end

  private

  attr_reader :rows, :target

  def state(config)
    [config.present?, config&.value.presence]
  end

  def before_state(entry)
    [entry[:was_present], entry[:before].presence]
  end

  def after_state(entry)
    case rows.fetch(entry[:name])
    when :target then [true, target]
    when :target_if_present then entry[:was_present] ? [true, target] : [false, nil]
    else entry[:was_present] ? [true, nil] : [false, nil]
    end
  end

  def describe(row_state)
    present, value = row_state
    return 'absent' unless present

    value.nil? ? 'blank' : value.inspect
  end

  def write!(name, config, present, value)
    return config&.destroy! unless present
    return config.update!(value: value) if config

    InstallationConfig.create!(name: name, value: value)
  end
end
