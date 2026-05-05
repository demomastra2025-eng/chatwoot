# frozen_string_literal: true

class Reminders::CampaignConflictPolicy
  CANCEL_REASON = 'отменен из-за рассылки'
  NOT_SENT_STATUSES = %w[pending submitted].freeze
  SENT_BLOCKING_STATUSES = %w[sent delivered read].freeze
  BLOCKING_STATUSES = (NOT_SENT_STATUSES + SENT_BLOCKING_STATUSES).freeze

  attr_reader :reminder, :conversation

  def initialize(reminder:, conversation: nil)
    @reminder = reminder
    @conversation = conversation
  end

  def conflict?
    blocking_delivery.present?
  end

  def cancel_if_conflict!
    delivery = blocking_delivery
    return false if delivery.blank?

    reminder.update!(
      status: :cancelled,
      cancelled_at: Time.current,
      processing_started_at: nil,
      last_error: CANCEL_REASON,
      metadata: conflict_metadata(delivery)
    )
    true
  end

  def blocking_delivery
    return unless automation_touch?
    return if contact.blank? || inbox.blank?

    candidate_deliveries.detect { |delivery| blocking_delivery?(delivery) }
  end

  private

  def automation_touch?
    metadata = reminder.metadata.to_h
    metadata['touch_source'] == 'automation' || metadata['automation_rule_id'].present?
  end

  def candidate_deliveries
    CampaignDelivery.includes(:campaign)
                    .where(account_id: reminder.account_id, contact_id: contact.id, inbox_id: inbox.id)
                    .where(status: CampaignDelivery.statuses.slice(*BLOCKING_STATUSES).values)
                    .order(updated_at: :desc, id: :desc)
  end

  def blocking_delivery?(delivery)
    campaign = delivery.campaign
    return false if campaign.failed? || campaign.cancelled?
    return not_sent_blocking?(delivery) if NOT_SENT_STATUSES.include?(delivery.status)

    sent_blocking?(delivery)
  end

  def not_sent_blocking?(delivery)
    delivery.campaign.active? || delivery.campaign.running? || delivery.pending? || delivery.submitted?
  end

  def sent_blocking?(delivery)
    SENT_BLOCKING_STATUSES.include?(delivery.status) && !customer_reply_after?(delivery)
  end

  def customer_reply_after?(delivery)
    reply_watermark = delivery.last_status_at || delivery.updated_at || delivery.created_at
    return false if reply_watermark.blank?

    Message.where(account_id: reminder.account_id, inbox_id: inbox.id)
           .where(conversation_id: same_contact_conversation_ids)
           .where(message_type: Message.message_types[:incoming], private: false, sender_type: 'Contact')
           .where('created_at > ?', reply_watermark)
           .exists?
  end

  def same_contact_conversation_ids
    Conversation.where(account_id: reminder.account_id, inbox_id: inbox.id, contact_id: contact.id).select(:id)
  end

  def contact
    @contact ||= conversation&.contact || reminder.target_contact || reminder.target_conversation&.contact || reminder.conversation&.contact
  end

  def inbox
    @inbox ||= conversation&.inbox || reminder.target_inbox || reminder.target_conversation&.inbox || reminder.conversation&.inbox
  end

  def conflict_metadata(delivery)
    reminder.metadata.to_h.merge(
      'cancelled_via' => 'campaign_conflict_policy',
      'cancelled_reason' => CANCEL_REASON,
      'cancelled_at' => Time.current.iso8601,
      'campaign_conflict_delivery_id' => delivery.id,
      'campaign_conflict_campaign_id' => delivery.campaign_id,
      'campaign_conflict_inbox_id' => delivery.inbox_id,
      'campaign_conflict_contact_id' => delivery.contact_id
    )
  end
end
