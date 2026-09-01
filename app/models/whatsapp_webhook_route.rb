# == Schema Information
#
# Table name: whatsapp_webhook_routes
#
#  id                 :bigint           not null, primary key
#  destination        :string           not null
#  registration_token :string(36)
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  phone_number_id    :string           not null
#  waba_id            :string           not null
#
# Indexes
#
#  idx_whatsapp_webhook_routes_exact  (waba_id,phone_number_id,destination) UNIQUE
#  idx_whatsapp_webhook_routes_waba   (waba_id)
#
class WhatsappWebhookRoute < ApplicationRecord
  DESTINATIONS = %w[dev widget].freeze
  DIGITS = /\A\d+\z/
  REGISTRATION_TOKEN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  scope :for_waba, ->(waba_id) { where(waba_id: waba_id) }
  scope :for_exact_route, ->(waba_id, phone_number_id) { where(waba_id: waba_id, phone_number_id: phone_number_id) }

  def self.local_prod_owner_exists?(waba_id, phone_number_id)
    Channel::Whatsapp.active_cloud
                     .for_waba(waba_id)
                     .exists?(["provider_config ->> 'phone_number_id' = ?", phone_number_id])
  end

  def self.with_waba_registry_lock(waba_id)
    lock_key = Digest::SHA256.hexdigest("whatsapp-webhook-registry:#{waba_id}").first(16).to_i(16) % ((2**63) - 1)

    transaction(requires_new: true) do
      connection.execute("SELECT pg_advisory_xact_lock(#{connection.quote(lock_key)})")
      yield
    end
  end

  validates :waba_id, presence: true, format: { with: DIGITS }
  validates :phone_number_id, presence: true, format: { with: DIGITS }
  validates :destination, presence: true, inclusion: { in: DESTINATIONS }
  validates :registration_token, format: { with: REGISTRATION_TOKEN }, allow_nil: true
end
