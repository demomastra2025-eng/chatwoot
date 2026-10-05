# frozen_string_literal: true

# The installation rows of the Luna 6 cut-over. A row is "present" with a value or absent; the cut-over moves each row
# to its after-state and a rollback to its before-state, and both refuse to run when a row is in neither state.
class Llm::CaptainLunaRollout::InstallationRows
  # rows: name => whether the cut-over creates the row when it is absent (a row that is absent stays absent otherwise)
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
    entries.each { |entry| write!(entry[:name], configs[entry[:name]], after_state(entry)) }
  end

  def restore!(entries, configs)
    entries.each { |entry| write!(entry[:name], configs[entry[:name]], before_state(entry)) }
  end

  private

  attr_reader :rows, :target

  def state(config)
    [config.present?, config&.value]
  end

  def before_state(entry)
    [entry[:was_present], entry[:before]]
  end

  def after_state(entry)
    keeps_row = entry[:was_present] || rows.fetch(entry[:name])
    keeps_row ? [true, target] : [false, nil]
  end

  def write!(name, config, wanted)
    present, value = wanted
    return config&.destroy! unless present
    return config.update!(value: value) if config

    InstallationConfig.create!(name: name, value: value)
  end
end
