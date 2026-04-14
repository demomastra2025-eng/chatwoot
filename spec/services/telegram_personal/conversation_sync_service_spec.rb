require 'rails_helper'

RSpec.describe TelegramPersonal::ConversationSyncService do
  let(:channel) { create(:channel_telegram_personal) }

  def build_contact_inbox(source_id: '23')
    TelegramPersonal::ContactSyncService.new(
      inbox: channel.inbox,
      params: {
        peer_user_id: source_id,
        chat_id: source_id,
        first_name: 'Sojan',
        last_name: 'Jose',
        username: 'sojan'
      }
    ).perform
  end

  it 'reuses the latest conversation for the same contact inbox' do
    contact_inbox = build_contact_inbox

    first_conversation = described_class.new(
      inbox: channel.inbox,
      contact_inbox: contact_inbox,
      activity_at: Time.zone.parse('2026-04-14T10:00:00Z'),
      additional_attributes: { chat_id: '23', peer_user_id: '23' }
    ).perform

    second_conversation = described_class.new(
      inbox: channel.inbox,
      contact_inbox: contact_inbox,
      activity_at: Time.zone.parse('2026-04-14T10:05:00Z'),
      additional_attributes: { chat_id: '23', peer_user_id: '23', username: 'sojan' }
    ).perform

    expect(channel.inbox.conversations.count).to eq(1)
    expect(second_conversation.id).to eq(first_conversation.id)
    expect(second_conversation.reload.last_activity_at.iso8601).to eq('2026-04-14T10:05:00Z')
    expect(second_conversation.additional_attributes).to include(
      'chat_id' => '23',
      'peer_user_id' => '23',
      'username' => 'sojan'
    )
  end

  it 'reuses the latest inbox conversation for an existing duplicated contact' do
    contact_inbox = build_contact_inbox
    duplicated_conversation = create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: contact_inbox.contact,
      contact_inbox: contact_inbox,
      last_activity_at: 2.minutes.ago
    )

    contact_inbox.conversations.create!(
      account: channel.account,
      inbox: channel.inbox,
      contact: contact_inbox.contact,
      status: :open
    )

    resolved_conversation = described_class.new(
      inbox: channel.inbox,
      contact_inbox: contact_inbox,
      activity_at: Time.current,
      additional_attributes: { chat_id: '23' }
    ).perform

    expect(resolved_conversation.id).to eq(duplicated_conversation.id)
  end

  it 'does not reuse resolved conversations when lock_to_single_conversation is disabled' do
    channel.inbox.update!(lock_to_single_conversation: false)
    contact_inbox = build_contact_inbox

    resolved_conversation = create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: contact_inbox.contact,
      contact_inbox: contact_inbox,
      status: :resolved,
      last_activity_at: 2.minutes.ago
    )

    active_conversation = described_class.new(
      inbox: channel.inbox,
      contact_inbox: contact_inbox,
      activity_at: Time.current,
      additional_attributes: { chat_id: '23' }
    ).perform

    expect(active_conversation.id).not_to eq(resolved_conversation.id)
    expect(active_conversation.status).not_to eq('resolved')
  end
end
