# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Voice::Conference::Manager do
  let(:account) { create(:account) }
  let(:voice_phone_number) { "+1555#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:channel) { create(:channel_voice, account: account, phone_number: voice_phone_number) }
  let(:inbox) { channel.inbox }
  let(:contact_phone_number) { "+1556#{SecureRandom.random_number(10**8).to_s.rjust(8, '0')}" }
  let(:contact) { create(:contact, account: account, phone_number: contact_phone_number) }
  let(:contact_inbox) { ContactInbox.create!(contact: contact, inbox: inbox, source_id: contact.phone_number) }
  let(:call_sid) { 'CATESTCONFERENCE123' }
  let(:conversation) do
    Conversation.create!(
      account_id: account.id,
      inbox_id: inbox.id,
      contact_id: contact.id,
      contact_inbox_id: contact_inbox.id,
      identifier: call_sid,
      additional_attributes: { 'call_direction' => 'inbound', 'call_status' => initial_status }
    )
  end
  let(:message) do
    conversation.messages.create!(
      account_id: account.id,
      inbox_id: inbox.id,
      message_type: :incoming,
      sender: contact,
      content: 'Voice Call',
      content_type: 'voice_call',
      content_attributes: { data: { call_sid: call_sid, status: initial_status } }
    )
  end
  let(:initial_status) { 'in-progress' }

  before do
    allow(Twilio::VoiceWebhookSetupService).to receive(:new)
      .and_return(instance_double(Twilio::VoiceWebhookSetupService, perform: "AP#{SecureRandom.hex(16)}"))
  end

  it 'completes a call when an agent leaves an in-progress conference using legacy status spelling' do
    message

    described_class.new(
      conversation: conversation,
      event: 'leave',
      call_sid: call_sid,
      participant_label: 'agent:1'
    ).process

    expect(conversation.reload.additional_attributes['call_status']).to eq('completed')
    expect(message.reload.content_attributes.dig('data', 'status')).to eq('completed')
  end

  it 'marks unanswered ringing conferences as no_answer when the participant leaves' do
    message
    conversation.update!(additional_attributes: conversation.additional_attributes.merge('call_status' => 'ringing'))
    message.update!(content_attributes: { data: { call_sid: call_sid, status: 'ringing' } })

    described_class.new(
      conversation: conversation,
      event: 'leave',
      call_sid: call_sid,
      participant_label: 'agent:1'
    ).process

    expect(conversation.reload.additional_attributes['call_status']).to eq('no_answer')
    expect(message.reload.content_attributes.dig('data', 'status')).to eq('no_answer')
  end
end
