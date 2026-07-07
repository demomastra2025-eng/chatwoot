# frozen_string_literal: true

class AddProfileKindToTelephonySipProfiles < ActiveRecord::Migration[7.0]
  def change
    add_column :telephony_sip_profiles, :profile_kind, :string, null: false, default: 'human_operator'
    change_column_null :telephony_sip_profiles, :user_id, true

    add_index :telephony_sip_profiles,
              %i[account_id inbox_id],
              unique: true,
              where: "profile_kind = 'voice_agent'",
              name: 'idx_tel_sip_profiles_one_voice_agent_per_inbox'
  end
end
