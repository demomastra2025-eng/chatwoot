require 'rails_helper'

RSpec.describe Reminders::PostDeliveryActionService do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account: account, role: :administrator) }
  let(:forged_rule) { create(:automation_rule, account: account) }
  let(:conversation) { create(:conversation, account: account, status: :open) }
  let(:reminder) do
    create(
      :reminder,
      account: account,
      touch_conversation: conversation,
      conversation: conversation,
      remindable: conversation,
      creator: actor,
      post_delivery_action: Reminder::POST_DELIVERY_ACTION_RESOLVE_CONVERSATION,
      metadata: {
        'touch_source' => 'automation',
        'automation_rule_id' => forged_rule.id
      }
    )
  end

  def materialized_message(source_id: 'provider-message-id', status: :sent, complete: true)
    reminder.mark_processing!
    message = create(
      :message,
      account: account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: status,
      source_id: source_id,
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => reminder.id, 'touch_source' => 'touch' },
      content_attributes: { 'touch_id' => reminder.id }
    )
    reminder.mark_delivery_materialized!(message.id)
    reminder.complete! if complete
    message
  end

  it 'resolves the conversation after the provider acknowledges the materialized message' do
    message = materialized_message

    expect { described_class.new(message: message).perform }
      .to change { conversation.reload.status }.from('open').to('resolved')
      .and change(ConversationStatusTransition, :count).by(1)

    expect(reminder.metadata).to include(
      'touch_source' => 'automation',
      'automation_rule_id' => forged_rule.id
    )
    expect(reminder.metadata).not_to include(
      Reminder::POST_DELIVERY_AUTOMATION_RULE_ID_KEY,
      Reminder::POST_DELIVERY_AUDIT_SOURCE_KEY
    )
    expect(reminder.reload).to be_post_delivery_action_executed_for(message.id)
    expect(ConversationStatusTransition.last).to have_attributes(
      conversation_id: conversation.id,
      actor: actor,
      source: 'api',
      to_status: 'resolved'
    )
  end

  it 'uses protected automation provenance for the transition audit' do
    trusted_rule = create(:automation_rule, account: account)
    reminder.update!(creator: nil)
    reminder.mark_automation_provenance!(trusted_rule)
    message = materialized_message

    expect(described_class.new(message: message).perform).to be(true)
    expect(ConversationStatusTransition.last).to have_attributes(
      actor: trusted_rule,
      source: 'automation'
    )
  end

  it 'fails closed when neither a trusted API creator nor automation provenance exists' do
    reminder.update!(creator: nil)
    message = materialized_message

    expect(described_class.new(message: message).perform).to be(false)
    expect(conversation.reload).to be_open
    expect(reminder.reload).not_to be_post_delivery_action_executed_for(message.id)
  end

  it 'does not lose a fast provider acknowledgement while the touch is still processing' do
    message = materialized_message(complete: false)

    expect(described_class.new(message: message).perform).to be(true)
    expect(conversation.reload).to be_resolved
    expect(reminder.reload).to be_post_delivery_action_executed_for(message.id)
  end

  it 'executes at most once across duplicate message update events' do
    message = materialized_message
    service = described_class.new(message: message)

    expect(service.perform).to be(true)
    expect(service.perform).to be(false)
    expect(ConversationStatusTransition.where(conversation: conversation, to_status: 'resolved').count).to eq(1)
  end

  it 'marks the action complete without duplicating a transition when the conversation is already resolved' do
    message = materialized_message
    conversation.update!(status: :resolved)

    expect { described_class.new(message: message).perform }
      .not_to change(ConversationStatusTransition, :count)
    expect(reminder.reload).to be_post_delivery_action_executed_for(message.id)
  end

  it 'rolls back the conversation transition when writing the execution marker fails' do
    message = materialized_message
    service = described_class.new(message: message)
    allow(service).to receive(:reminder_for_message).and_return(reminder)
    allow(reminder).to receive(:mark_post_delivery_action_executed!).and_raise('marker write failed')

    expect { service.perform }.to raise_error('marker write failed')
    expect(conversation.reload).to be_open
    expect(ConversationStatusTransition.where(conversation: conversation)).to be_empty
  end

  it 'waits through a deferred provider retry and executes only after a provider id is present' do
    message = materialized_message(source_id: nil)

    expect(described_class.new(message: message).perform).to be(false)
    expect(conversation.reload).to be_open

    message.update!(source_id: 'provider-message-id', status: :sent)

    expect(described_class.new(message: message).perform).to be(true)
    expect(conversation.reload).to be_resolved
  end

  it 'does not resolve for a failed message even when a provider id is present' do
    message = materialized_message(status: :failed)

    expect(described_class.new(message: message).perform).to be(false)
    expect(conversation.reload).to be_open
    expect(reminder.reload).not_to be_post_delivery_action_executed_for(message.id)
  end

  it 'does not resolve for another message carrying the same touch id' do
    materialized_message
    other_message = create(
      :message,
      account: account,
      inbox: conversation.inbox,
      conversation: conversation,
      message_type: :outgoing,
      source_id: 'another-provider-message-id',
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => reminder.id }
    )

    expect(described_class.new(message: other_message).perform).to be(false)
    expect(conversation.reload).to be_open
  end

  it 'fails closed for malformed or conflicting touch provenance' do
    message = materialized_message

    message.update!(
      additional_attributes: { 'touch_id' => 'not-an-id' },
      content_attributes: {}
    )
    message.reload
    expect(described_class.new(message: message).perform).to be(false)

    message.update!(
      additional_attributes: { 'touch_id' => reminder.id },
      content_attributes: { 'touch_id' => reminder.id + 1 }
    )
    message.reload
    expect(described_class.new(message: message).perform).to be(false)
    expect(conversation.reload).to be_open
  end

  it 'does not resolve an unrelated conversation' do
    message = materialized_message
    other_conversation = create(:conversation, account: account, status: :open)
    message.update!(conversation_id: other_conversation.id)
    message.reload

    expect(described_class.new(message: message).perform).to be(false)
    expect(conversation.reload).to be_open
    expect(other_conversation.reload).to be_open
  end

  it 'does not resolve a touch from another account' do
    other_conversation = create(:conversation, status: :open)
    other_message = create(
      :message,
      account: other_conversation.account,
      inbox: other_conversation.inbox,
      conversation: other_conversation,
      message_type: :outgoing,
      source_id: 'other-account-provider-id',
      skip_send_reply: true,
      additional_attributes: { 'touch_id' => reminder.id },
      content_attributes: { 'touch_id' => reminder.id }
    )

    expect(described_class.new(message: other_message).perform).to be(false)
    expect(conversation.reload).to be_open
    expect(other_conversation.reload).to be_open
  end
end
