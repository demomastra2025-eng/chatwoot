# frozen_string_literal: true

module InstallationConfigHelpers
  def upsert_installation_config(name, value)
    InstallationConfig.find_or_initialize_by(name: name).tap do |config|
      config.value = value
      config.save!
    end
  end
end
