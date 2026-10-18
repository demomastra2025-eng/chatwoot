# frozen_string_literal: true

module InstallationConfigHelpers
  # locked: false makes the row one that a settings page saved (the rows the read-only list of the super admin shows)
  def upsert_installation_config(name, value, locked: nil)
    InstallationConfig.find_or_initialize_by(name: name).tap do |config|
      config.value = value
      config.locked = locked unless locked.nil?
      config.save!
    end
  end
end
