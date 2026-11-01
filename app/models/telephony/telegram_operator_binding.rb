class Telephony::TelegramOperatorBinding < ApplicationRecord
  self.table_name = 'telephony_telegram_operator_bindings'

  LINK_TOKEN_TTL = 15.minutes
  ACTIVE_MEMBER_SQL = <<~SQL.squish.freeze
    EXISTS (
      SELECT 1 FROM account_users au
      WHERE au.account_id = telephony_telegram_operator_bindings.account_id
        AND au.user_id = telephony_telegram_operator_bindings.user_id
    )
  SQL

  belongs_to :account, class_name: '::Account', inverse_of: :telephony_telegram_operator_bindings
  belongs_to :user, class_name: '::User', inverse_of: :telephony_telegram_operator_bindings

  before_destroy :deactivate_sip_before_destroy

  validates :user_id, uniqueness: { scope: :account_id }
  validates :telegram_user_id, uniqueness: { scope: :account_id }, allow_blank: true
  validate :validate_user_account_membership

  scope :active_member, -> { where(ACTIVE_MEMBER_SQL) }
  scope :connected, lambda {
    active_member
      .where.not(telegram_user_id: [nil, ''])
      .where.not(telegram_chat_id: [nil, ''])
      .where.not(verified_at: nil)
  }
  scope :on_line, -> { connected.where(on_line: true) }

  def self.digest_token(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  def self.consume_link_token!(raw_token, from:, chat_id:)
    return nil if raw_token.blank? || from.blank? || chat_id.blank?

    digest = digest_token(raw_token)
    binding = find_by(link_token_digest: digest)
    return nil unless binding

    binding.consume_token_with_lock!(digest: digest, from: from, chat_id: chat_id)
  end

  def active_account_member?
    account_id.present? && user_id.present? && AccountUser.exists?(account_id: account_id, user_id: user_id)
  end

  def connected?
    telegram_user_id.present? && telegram_chat_id.present? && verified_at.present? && active_account_member?
  end

  def issue_link_token!
    raw_token = SecureRandom.urlsafe_base64(24)
    expires_at = LINK_TOKEN_TTL.from_now
    update!(
      link_token_digest: self.class.digest_token(raw_token),
      link_token_expires_at: expires_at
    )
    {
      token: raw_token,
      deep_link: TelegramCalls::Config.deep_link_for(raw_token),
      bot_username: TelegramCalls::Config.bot_username,
      expires_at: expires_at.iso8601
    }
  end

  def consume_token_with_lock!(digest:, from:, chat_id:)
    with_lock do
      reload
      return nil if link_token_digest != digest
      return nil if link_token_expires_at.blank? || link_token_expires_at <= Time.current
      return nil unless active_account_member?

      apply_telegram_identity!(from: from, chat_id: chat_id)
    end
    self
  end

  def update_verified_phone!(raw_phone)
    digits = raw_phone.to_s.gsub(/\D/, '')
    return false if digits.length < 7

    update!(phone_number: "+#{digits}")
  end

  def go_on_line!(sync_sip: true)
    raise_not_connected! unless connected?

    TelegramCalls::SipLineSyncService.new(binding: self).activate! if sync_sip
    update!(on_line: true, on_line_since: on_line_since || Time.current)
    reload
  end

  def go_off_line!(sync_sip: true)
    TelegramCalls::SipLineSyncService.new(binding: self).deactivate! if sync_sip && sip_lease_meta.present?
    update!(on_line: false, on_line_since: nil, sip_lease_meta: {})
    reload
  end

  def disconnect!(sync_sip: true)
    go_off_line!(sync_sip: sync_sip)
    update!(
      telegram_user_id: nil, telegram_chat_id: nil, username: nil,
      first_name: nil, last_name: nil, phone_number: nil,
      verified_at: nil, link_token_digest: nil, link_token_expires_at: nil
    )
    reload
  end

  def registered_sip_lines
    Array.wrap(sip_lease_meta.to_h['lines']).select { |item| item.is_a?(Hash) }
  end

  def status_payload
    {
      configured: TelegramCalls::Config.configured?,
      voice_gateway_configured: TelegramCalls::Config.voice_gateway_configured?,
      bot_username: TelegramCalls::Config.bot_username,
      connected: connected?,
      on_line: connected? && on_line?,
      on_line_since: on_line_since&.iso8601,
      username: username,
      first_name: first_name,
      last_name: last_name,
      has_phone_number: phone_number.present?,
      sip_lines: sanitized_sip_lines
    }
  end

  private

  def apply_telegram_identity!(from:, chat_id:)
    data = from.to_h.stringify_keys
    tg_id = data['id'].to_s
    release_conflicting_account_bindings!(tg_id)
    update!(
      telegram_user_id: tg_id, telegram_chat_id: chat_id.to_s,
      username: data['username'].presence, first_name: data['first_name'].presence,
      last_name: data['last_name'].presence, verified_at: Time.current,
      link_token_digest: nil, link_token_expires_at: nil
    )
  end

  def release_conflicting_account_bindings!(tg_id)
    return if tg_id.blank?

    self.class.where(account_id: account_id, telegram_user_id: tg_id)
        .where.not(id: id)
        .find_each(&:disconnect!)
  end

  def deactivate_sip_before_destroy
    return if sip_lease_meta.blank?

    TelegramCalls::SipLineSyncService.new(binding: self).deactivate!
  rescue StandardError => e
    Rails.logger.warn("TELEGRAM_CALLS_DESTROY_DEACTIVATE_WARN binding=#{id} error=#{e.message}")
  end

  def sanitized_sip_lines
    registered_sip_lines.map do |line|
      line.slice('line_key', 'inbox_id', 'sip_profile_id', 'provider', 'registered', 'error')
    end
  end

  def validate_user_account_membership
    return unless requires_active_membership?
    return if account.blank? || user_id.blank?
    return if account.account_users.exists?(user_id: user_id)

    errors.add(:user_id, :invalid)
  end

  def requires_active_membership?
    new_record? || ownership_changing? || activating_binding_state?
  end

  def ownership_changing?
    will_save_change_to_account_id? || will_save_change_to_user_id?
  end

  def activating_binding_state?
    (on_line? && will_save_change_to_on_line?) ||
      (telegram_user_id.present? && will_save_change_to_telegram_user_id?) ||
      (link_token_digest.present? && will_save_change_to_link_token_digest?)
  end

  def raise_not_connected!
    raise Telephony::Error.new(
      code: 'TELEGRAM_NOT_CONNECTED',
      message: 'Telegram account is not linked yet',
      status: :unprocessable_content
    )
  end
end
