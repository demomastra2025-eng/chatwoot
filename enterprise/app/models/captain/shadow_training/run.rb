# frozen_string_literal: true

# Local evidence only. Never a reply suggestion, a session, or approved knowledge.
class Captain::ShadowTraining::Run < ApplicationRecord
  self.table_name = 'captain_shadow_training_runs'

  belongs_to :account, class_name: '::Account'
  belongs_to :conversation, class_name: '::Conversation'
  belongs_to :assistant, class_name: '::Captain::Assistant', optional: true
  belongs_to :user, class_name: '::User'
  belongs_to :inbound_message, class_name: '::Message'
  belongs_to :human_message, class_name: '::Message'
  has_many :candidates, class_name: 'Captain::ShadowTraining::Candidate', dependent: :destroy

  validates :status, inclusion: { in: %w[queued generating awaiting_comparison comparing completed failed skipped pending_routing
                                         interrupted_pending_review pending_input] }
  validates :human_reply, :snapshot, presence: true
  validates :human_reply, length: { maximum: 150_000 }
  validate :same_account, on: :create
  validate :assistant_account
  attr_readonly :account_id, :conversation_id, :user_id, :inbound_message_id, :human_message_id, :snapshot, :human_reply

  def source_owned?
    records_owned? && operator_owned? && inbound_owned?
  end

  def evaluation_snapshot(actor_id = assistant_id)
    context = snapshot.fetch('agent_contexts').fetch(actor_id.to_s)
    snapshot.merge('system_prompt' => context.fetch('system_prompt'), 'facts' => snapshot.fetch('facts') + context.fetch('faq'))
  end

  private

  def assistant_account
    errors.add(:assistant, 'must belong to this account') if assistant && assistant.account_id != account_id
  end

  def inbound_owned?
    inbound_message.incoming? && !inbound_message.private? && inbound_message.sender_type == 'Contact' &&
      inbound_message.sender_id == conversation.contact_id
  end

  def records_owned?
    return false if [account, conversation, inbound_message, human_message].any?(&:nil?)

    [conversation, assistant, inbound_message, human_message].compact.all? { |record| record.account_id == account_id } &&
      [inbound_message, human_message].all? { |record| record.conversation_id == conversation_id }
  end

  def operator_owned?
    human_message.sender_type == 'User' && human_message.sender_id == user_id && account.users.exists?(id: user_id)
  end

  def same_account
    errors.add(:base, 'Shadow sources must belong to this account and operator') unless source_owned?
  end
end
