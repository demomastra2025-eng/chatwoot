# frozen_string_literal: true

# The dialog of a person (communication threads) is the only way to start a conversation from the screen: «Написать», «Новое
# сообщение», the calendar and the deals all open it. A clinic without the flag could not write to anybody first, so a NEW clinic
# starts with it on. Only the default for new accounts changes here: the accounts that exist keep the flag they have (the owner
# switches it per clinic in «Служебные»).
class EnableCommunicationThreadsDefaultFeatureFlag < ActiveRecord::Migration[7.1]
  FEATURE_NAME = 'communication_threads'

  def up
    change_default(true)
  end

  def down
    change_default(false)
  end

  private

  def change_default(enabled)
    config = InstallationConfig.find_by(name: 'ACCOUNT_LEVEL_FEATURE_DEFAULTS')
    return if config.blank? || config.value.blank?

    # An installation that has no such default yet gets it from config/features.yml (ConfigLoader), which is on.
    features = config.value.map { |feature| feature['name'] == FEATURE_NAME ? feature.merge('enabled' => enabled) : feature }
    return if features == config.value

    config.value = features
    config.save!
    GlobalConfig.clear_cache
  end
end
