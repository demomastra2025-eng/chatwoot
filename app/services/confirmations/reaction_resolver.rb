# frozen_string_literal: true

class Confirmations::ReactionResolver
  POSITIVE_EMOJIS = %w[
    👍 👍🏻 👍🏼 👍🏽 👍🏾 👍🏿
    ✅ ☑️ ✔️
    👌 👌🏻 👌🏼 👌🏽 👌🏾 👌🏿
    ❤️ ♥️ ❤️‍🔥
    🙏 🙏🏻 🙏🏼 🙏🏽 🙏🏾 🙏🏿
    🤝 ➕ 💯
  ].freeze

  NEGATIVE_EMOJIS = %w[
    👎 👎🏻 👎🏼 👎🏽 👎🏾 👎🏿
    ❌ ✖️ 🚫
  ].freeze

  def self.classify_emoji(emoji)
    cleaned = emoji.to_s.strip
    return nil if cleaned.blank?
    return 'confirmed' if POSITIVE_EMOJIS.include?(cleaned)
    return 'declined' if NEGATIVE_EMOJIS.include?(cleaned)

    nil
  end

  def initialize(target_message:, emoji:)
    @target_message = target_message
    @emoji = emoji.to_s.strip
    @conversation = target_message&.conversation
    @account = target_message&.account
  end

  def perform
    return { handled: false, reason: 'blank_context' } if target_message.blank? || conversation.blank? || account.blank?

    decision = self.class.classify_emoji(emoji)
    return { handled: false, reason: 'unrecognized_emoji' } if decision.blank?

    if pending_request.present?
      Confirmations::ResolveService.new(
        account: account,
        confirmation_request: pending_request,
        decision: decision,
        source: 'text',
        message: target_message,
        confidence: 0.97,
        metadata: { 'resolver' => 'reaction_emoji', 'emoji' => emoji }
      ).perform
      auto_confirm_scheduled_appointment! if decision == 'confirmed'

      return {
        handled: true,
        decision: decision,
        confirmation_request_id: pending_request.id
      }
    end

    if decision == 'confirmed' && auto_confirm_scheduled_appointment!
      return {
        handled: true,
        decision: 'confirmed',
        auto_confirmed_appointment: true
      }
    end

    { handled: false, reason: 'no_pending_target' }
  rescue StandardError => e
    Rails.logger.warn("[Confirmations::ReactionResolver] Failed on message=#{target_message&.id}: #{e.class}: #{e.message}")
    { handled: false, reason: 'error' }
  end

  private

  attr_reader :target_message, :emoji, :conversation, :account

  def pending_request
    return @pending_request if defined?(@pending_request)

    scope = ConfirmationRequest
            .where(account_id: account.id, conversation_id: conversation.id, inbox_id: conversation.inbox_id)
            .active_pending

    direct = scope.find_by(delivery_message_id: target_message.id)
    return @pending_request = direct if direct.present?

    candidates = scope.latest_first.limit(2).to_a
    @pending_request = candidates.one? ? candidates.first : nil
  end

  def auto_confirm_scheduled_appointment!
    scope = Scheduling::Appointment
            .where(account_id: account.id)
            .where('conversation_id = :cid OR contact_id = :contact_id', cid: conversation.id, contact_id: conversation.contact_id)
            .where(status: 'scheduled')
            .where('starts_at >= ?', Time.current)
            .order(:starts_at)
            .limit(2)
            .to_a

    return false unless scope.one?

    scope.first.update!(status: 'confirmed')
    true
  end
end
