require 'rails_helper'

RSpec.describe TelegramPersonal::EnrichHistoryMediaService do
  before do
    stub_request(:get, 'https://chatwoot-assets.local/old-photo.png').to_return(
      status: 200,
      body: File.read(Rails.root.join('spec/assets/sample.png')),
      headers: { 'Content-Type' => 'image/png' }
    )
  end

  let(:channel) { create(:channel_telegram_personal) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: channel.account) }
  let(:contact_inbox) { create(:contact_inbox, inbox: inbox, contact: contact, source_id: '6002671687') }
  let(:conversation) do
    create(
      :conversation,
      account: channel.account,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      additional_attributes: { 'chat_id' => '6002671687', 'peer_user_id' => '6002671687' }
    )
  end

  it 'fetches skipped historical media from the gateway and enriches the message without firing runtime events' do
    message = create(
      :message,
      account: channel.account,
      inbox: inbox,
      conversation: conversation,
      source_id: '701',
      content: '[Attachment]',
      content_attributes: {
        'imported_history' => true,
        'telegram_history_media_incomplete' => true,
        'telegram_history_media_skipped_message_ids' => ['701']
      }
    )

    gateway_client = instance_double(TelegramPersonal::GatewayClient)
    allow(TelegramPersonal::GatewayClient).to receive(:new).with(channel: channel).and_return(gateway_client)
    expect(gateway_client).to receive(:enrich_message_media!).with(
      chat_id: '6002671687',
      peer_user_id: '6002671687',
      message_id: '701',
      telegram_message_ids: []
    ).and_return(
      payload: {
        message_id: '701',
        imported_history: true,
        history_media_incomplete: false,
        chat_id: '6002671687',
        peer_user_id: '6002671687',
        sender_id: '6002671687',
        chat_type: 'private',
        attachments: [
          {
            kind: 'photo',
            url: 'https://chatwoot-assets.local/old-photo.png',
            filename: 'old-photo.png',
            content_type: 'image/png',
            telegram_message_id: '701'
          }
        ]
      }
    )

    enriched = described_class.new(message: message).perform

    expect(enriched.attachments.count).to eq(1)
    expect(enriched.content).to eq('')
    expect(enriched.content_attributes).not_to have_key('telegram_history_media_incomplete')
  end

  it 'returns the message immediately when media is already complete' do
    message = create(
      :message,
      account: channel.account,
      inbox: inbox,
      conversation: conversation,
      source_id: '702',
      content: 'complete message',
      content_attributes: { 'imported_history' => true }
    )

    expect(TelegramPersonal::GatewayClient).not_to receive(:new)

    expect(described_class.new(message: message).perform).to eq(message)
  end
end
