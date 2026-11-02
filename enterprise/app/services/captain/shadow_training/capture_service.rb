# frozen_string_literal: true

class Captain::ShadowTraining::CaptureService
  def self.call(message)
    new(message).call
  end

  def initialize(message)
    @message = message
  end

  def call
    return unless Captain::ShadowTraining::Eligibility.allowed?(@message.account)
    return unless Captain::ShadowTraining::Eligibility.human_reply?(@message)
    return if Compliance::ExplicitAiConsentGate.blocked?(@message.conversation)

    run = capture
    Captain::ShadowTraining::RunJob.perform_later(run.id) if run&.status == 'queued'
    run
  end

  private

  def capture
    @message.conversation.with_lock do
      inbound = matching_inbound
      return unless inbound && first_reply?(inbound)

      existing = Captain::ShadowTraining::Run.find_by(account_id: @message.account_id, inbound_message_id: inbound.id)
      return existing if existing

      create_run(inbound)
    end
  end

  def matching_inbound
    inbound = before(@message).where(message_type: :incoming, sender_type: 'Contact', private: false).reorder(created_at: :desc, id: :desc).first
    inbound if inbound&.content.present? && inbound.sender_id == @message.conversation.contact_id
  end

  # Async events can arrive out of order: choose by persisted send order, never event delivery order.
  def first_reply?(inbound)
    human = after(inbound).where(message_type: :outgoing, sender_type: 'User', private: false).where.not(status: :failed)
                          .where(Message.person_activity_sql).reorder(:created_at, :id).first
    human&.id == @message.id
  end

  def create_run(inbound)
    scope = Captain::ChannelScope.for_conversation(@message.conversation)
    agents = Captain::AgentGraph.new(scope).candidates
    holder = Captain::Conversation::AgentOwnership.new(conversation: @message.conversation).current_assistant
    Captain::ShadowTraining::Run.create!(
      account: @message.account, conversation: @message.conversation, user: @message.sender,
      assistant: (agents.first if agents.one?), inbound_message: inbound, human_message: @message,
      human_reply: @message.content,
      snapshot: Captain::ShadowTraining::Snapshot.new(inbound, agents, current_assistant_id: holder&.id).call
    )
  end

  def messages
    @message.conversation.messages.where(account_id: @message.account_id).without_imported_history
  end

  def before(message)
    messages.where('(created_at, id) < (?, ?)', message.created_at, message.id)
  end

  def after(message)
    messages.where('(created_at, id) > (?, ?)', message.created_at, message.id)
  end
end
