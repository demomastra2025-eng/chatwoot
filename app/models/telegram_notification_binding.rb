# frozen_string_literal: true

# == Schema Information
#
# Table name: telegram_notification_bindings
#
#  id               :bigint           not null, primary key
#  first_name       :string
#  last_name        :string
#  username         :string
#  verified_at      :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  telegram_chat_id :string
#  telegram_user_id :string
#  user_id          :bigint           not null
#
# Indexes
#
#  index_telegram_notification_bindings_on_telegram_user_id  (telegram_user_id) UNIQUE WHERE (telegram_user_id IS NOT NULL)
#  index_telegram_notification_bindings_on_user_id           (user_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (user_id => users.id)
#
class TelegramNotificationBinding < ApplicationRecord
  belongs_to :user

  validates :user_id, uniqueness: true
  validates :telegram_user_id, uniqueness: true, allow_blank: true

  def self.find_user_by_profile_token(token)
    access_token = AccessToken.find_by(token: token.to_s.strip)
    return unless access_token&.owner.is_a?(User)

    access_token.owner
  end

  def self.verify_user_from_telegram!(user, message)
    binding = user.telegram_notification_binding || user.build_telegram_notification_binding
    binding.verify_from_telegram!(message)
    binding
  end

  def connected?
    verified_at.present? && telegram_chat_id.present?
  end

  def pending_verification?
    false
  end

  def verify_from_telegram!(message)
    telegram_from = message.fetch(:from, {})
    chat = message.fetch(:chat, {})
    telegram_user_id_value = telegram_from[:id].to_s

    existing_binding = self.class.where(telegram_user_id: telegram_user_id_value).where.not(id: id).first
    raise ActiveRecord::RecordInvalid, existing_binding if existing_binding.present?

    update!(
      telegram_user_id: telegram_user_id_value,
      telegram_chat_id: chat[:id].to_s,
      username: telegram_from[:username],
      first_name: telegram_from[:first_name],
      last_name: telegram_from[:last_name],
      verified_at: Time.current
    )
  end

  def disconnect!
    update!(
      telegram_user_id: nil,
      telegram_chat_id: nil,
      username: nil,
      first_name: nil,
      last_name: nil,
      verified_at: nil
    )
  end

  def status_payload
    {
      connected: connected?,
      pending: pending_verification?,
      username: username,
      first_name: first_name,
      last_name: last_name,
      verified_at: verified_at,
      bot_username: ENV.fetch('TELEGRAM_NOTIFICATION_BOT_USERNAME', nil)
    }
  end
end
