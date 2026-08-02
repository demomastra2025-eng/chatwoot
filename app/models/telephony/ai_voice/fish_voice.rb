class Telephony::AiVoice::FishVoice < ApplicationRecord
  self.table_name = 'telephony_ai_voice_fish_voices'

  belongs_to :account
  belongs_to :created_by, class_name: 'User', optional: true

  validates :provider_model_id, presence: true, uniqueness: true
  validates :title, presence: true, length: { maximum: 100 }
  validates :state, :visibility, presence: true

  scope :recent_first, -> { order(created_at: :desc) }
  scope :selectable, -> { where(state: 'trained', visibility: 'private') }

  def self.with_provider_model_lock(provider_model_id)
    transaction do
      quoted_id = connection.quote(provider_model_id)
      connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{quoted_id}))")
      yield
    end
  end

  def self.with_account_lock(account, &)
    account.with_lock(&)
  end

  def trained?
    state == 'trained'
  end

  def selected_assistants
    Captain::Assistant.for_account(account_id)
                      .where("config -> 'voice_settings' ->> 'provider' = ?", 'fish')
                      .where("config -> 'voice_settings' ->> 'voice' = ?", provider_model_id)
  end

  def selected_assistants_count
    selected_assistants.count
  end
end
