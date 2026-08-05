require 'rails_helper'

RSpec.describe Confirmations::WhatsappReplyResolver do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      sync_templates: false,
      validate_provider_config: false
    )
  end
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let!(:first_delivery) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, source_id: 'wamid.FIRST')
  end
  let!(:second_delivery) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, source_id: 'wamid.SECOND')
  end
  let!(:first_request) do
    create(
      :confirmation_request,
      account: account,
      inbox: inbox,
      contact: contact,
      conversation: conversation,
      delivery_message: first_delivery
    )
  end
  let!(:second_request) do
    create(
      :confirmation_request,
      account: account,
      inbox: inbox,
      contact: contact,
      conversation: conversation,
      delivery_message: second_delivery
    )
  end

  it 'resolves only the request named by the signed button payload when several are pending' do
    reply = incoming_button(
      'interactive_reply_id' => "confirmation:#{first_request.token}:confirmed",
      'button_text' => 'Подтвердить'
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: true, confirmation_request_id: first_request.id)
    expect(first_request.reload).to be_confirmed
    expect(second_request.reload).to be_pending
  end

  it 'uses the exact replied-to delivery message for a static quick-reply payload' do
    reply = incoming_button(
      'button_payload' => 'Подтвердить',
      'button_text' => 'Подтвердить',
      'in_reply_to_external_id' => second_delivery.source_id
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: true, confirmation_request_id: second_request.id)
    expect(first_request.reload).to be_pending
    expect(second_request.reload).to be_confirmed
  end

  it 'fails closed instead of guessing when a static reply has several pending requests' do
    reply = incoming_button('button_payload' => 'Подтвердить', 'button_text' => 'Подтвердить')

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: false, reason: 'ambiguous')
    expect(first_request.reload).to be_pending
    expect(second_request.reload).to be_pending
  end

  it 'resolves an appointment confirmation only from its exact signed button payload' do
    first_request.destroy!
    second_request.destroy!
    strict_first = create_button_only_request(delivery: first_delivery)
    strict_second = create_button_only_request(delivery: second_delivery)
    reply = incoming_button(
      'interactive_reply_id' => "confirmation:#{strict_first.token}:confirmed",
      'button_text' => 'Подтвердить'
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: true, confirmation_request_id: strict_first.id)
    expect(strict_first.reload).to be_confirmed
    expect(strict_second.reload).to be_pending
  end

  it 'ignores a manual text reply even when it matches the appointment button label' do
    first_request.destroy!
    strict_request = create_button_only_request(delivery: first_delivery)
    reply = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Подтвердить',
      content_attributes: { 'in_reply_to_external_id' => first_delivery.source_id }
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: false, reason: 'button_payload_required')
    expect(strict_request.reload).to be_pending
    expect(second_request.reload).to be_pending
  end

  it 'does not fall back to another request when replying to an expired appointment confirmation' do
    first_request.destroy!
    strict_request = create_button_only_request(delivery: first_delivery)
    strict_request.update_column(:expires_at, 1.minute.ago)
    reply = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Подтвердить',
      content_attributes: { 'in_reply_to_external_id' => first_delivery.source_id }
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: false, reason: 'no_pending_request')
    expect(strict_request.reload).to be_pending
    expect(second_request.reload).to be_pending
  end

  it 'ignores a static button-shaped reply without the signed appointment payload' do
    first_request.destroy!
    strict_request = create_button_only_request(delivery: first_delivery)
    reply = incoming_button(
      'button_payload' => 'Подтвердить',
      'button_text' => 'Подтвердить',
      'in_reply_to_external_id' => first_delivery.source_id
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: false, reason: 'button_payload_required')
    expect(strict_request.reload).to be_pending
    expect(second_request.reload).to be_pending
  end

  it 'does not fall back from an expired appointment button event to another request' do
    first_request.destroy!
    strict_request = create_button_only_request(delivery: first_delivery)
    strict_request.update_column(:expires_at, 1.minute.ago)
    reply = incoming_button(
      'button_payload' => 'Подтвердить',
      'button_text' => 'Подтвердить',
      'in_reply_to_external_id' => first_delivery.source_id
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: false, reason: 'no_pending_request')
    expect(strict_request.reload).to be_pending
    expect(second_request.reload).to be_pending
  end

  it 'ignores matching plain text when the appointment request is the only pending confirmation' do
    first_request.destroy!
    second_request.destroy!
    strict_request = create_button_only_request(delivery: first_delivery)
    reply = create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Подтвердить'
    )

    result = described_class.new(account: account, conversation: conversation, message: reply).perform

    expect(result).to include(handled: false, reason: 'button_payload_required')
    expect(strict_request.reload).to be_pending
  end

  def incoming_button(content_attributes)
    create(
      :message,
      account: account,
      inbox: inbox,
      conversation: conversation,
      message_type: :incoming,
      content: 'Подтвердить',
      content_attributes: content_attributes
    )
  end

  def create_button_only_request(delivery:)
    channel.update!(
      message_templates: [
        {
          'name' => 'appointment_confirmation',
          'language' => 'ru',
          'status' => 'APPROVED',
          'components' => [
            { 'type' => 'BODY', 'text' => 'Подтвердите запись' },
            { 'type' => 'BUTTONS', 'buttons' => [{ 'type' => 'QUICK_REPLY', 'text' => 'Подтвердить' }] }
          ]
        }
      ]
    )
    appointment = create(
      :scheduling_appointment,
      account: account,
      contact: contact,
      conversation: conversation,
      starts_at: 1.day.from_now,
      ends_at: 1.day.from_now + 30.minutes
    )
    touch = create(
      :reminder,
      account: account,
      conversation: conversation,
      target_conversation: conversation,
      target_inbox: inbox,
      target_contact: contact,
      target_contact_inbox: contact_inbox,
      remindable: appointment,
      content_kind: :channel_template,
      body: nil,
      template_params: { name: 'appointment_confirmation', language: 'ru' },
      response_action: 'confirm_appointment',
      response_button_index: 0,
      scheduled_at: 1.hour.from_now
    )

    create(
      :confirmation_request,
      account: account,
      inbox: inbox,
      contact: contact,
      conversation: conversation,
      delivery_message: delivery,
      subject: appointment,
      reminder: touch
    )
  end
end
