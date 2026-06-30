class AddSipPasswordToTelephonySipProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :telephony_sip_profiles, :sip_password, :text
  end
end
