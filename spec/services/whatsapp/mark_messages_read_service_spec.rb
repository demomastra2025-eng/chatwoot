require 'rails_helper'

RSpec.describe Whatsapp::MarkMessagesReadService do
  let(:channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let(:conversation) { create(:conversation, inbox: channel.inbox) }
  let(:provider_service) { instance_double(Whatsapp::Providers::WhatsappCloudService) }

  it 'marks only the latest unread message because Meta also marks earlier messages read' do
    older_message = create(
      :message,
      conversation: conversation,
      inbox: channel.inbox,
      message_type: :incoming,
      source_id: 'wamid.older',
      created_at: 2.minutes.ago
    )
    latest_message = create(
      :message,
      conversation: conversation,
      inbox: channel.inbox,
      message_type: :incoming,
      source_id: 'wamid.latest',
      created_at: 1.minute.ago
    )
    allow(channel).to receive(:provider_service).and_return(provider_service)
    allow(provider_service).to receive(:mark_message_read).with('wamid.latest').and_return(true)

    result = described_class.new(
      conversation: conversation,
      messages: [latest_message, older_message]
    ).perform

    expect(result).to be(true)
    expect(provider_service).to have_received(:mark_message_read).once
  end

  it 'does not send provider read receipts for imported history or messages older than the provider window' do
    history_message = create(
      :message,
      conversation: conversation,
      inbox: channel.inbox,
      message_type: :incoming,
      source_id: 'wamid.history',
      created_at: 1.minute.ago,
      content_attributes: { 'whatsapp_history_import' => true }
    )
    stale_message = create(
      :message,
      conversation: conversation,
      inbox: channel.inbox,
      message_type: :incoming,
      source_id: 'wamid.stale',
      created_at: 31.days.ago
    )
    allow(channel).to receive(:provider_service).and_return(provider_service)
    expect(provider_service).not_to receive(:mark_message_read)

    result = described_class.new(conversation: conversation, messages: [history_message, stale_message]).perform

    expect(result).to be(false)
  end
end
