class UpgradeWhatsappGraphApiVersionToV25 < ActiveRecord::Migration[7.1]
  TARGET_VERSION = 'v25.0'.freeze

  def up
    config = InstallationConfig.find_by(name: 'WHATSAPP_API_VERSION')
    return if config.blank?

    match = config.value.to_s.match(/\Av(\d+)(?:\.\d+)?\z/)
    return if match.blank? || match[1].to_i >= 25

    config.update!(value: TARGET_VERSION)
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'Deprecated WhatsApp Graph API versions cannot be restored safely'
  end
end
