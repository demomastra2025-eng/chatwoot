class WhatsappWebhookRoute < ApplicationRecord
  DESTINATIONS = %w[dev widget].freeze
  DIGITS = /\A\d+\z/

  scope :for_waba, ->(waba_id) { where(waba_id: waba_id) }
  scope :for_exact_route, ->(waba_id, phone_number_id) { where(waba_id: waba_id, phone_number_id: phone_number_id) }

  def self.local_prod_owner_exists?(waba_id, phone_number_id)
    Channel::Whatsapp.active_cloud
                     .for_waba(waba_id)
                     .exists?(["provider_config ->> 'phone_number_id' = ?", phone_number_id])
  end

  validates :waba_id, presence: true, format: { with: DIGITS }
  validates :phone_number_id, presence: true, format: { with: DIGITS }
  validates :destination, presence: true, inclusion: { in: DESTINATIONS }
end
