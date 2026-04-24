require 'rails_helper'

RSpec.describe WhatsappWeb::RetryFailedProvisionalMessagesService do
  subject(:service) { described_class.new(channel: channel, contact: contact) }

  around do |example|
    with_modified_env(
      'EVOLUTION_API_URL' => 'https://evolution.example.com',
      'EVOLUTION_API_KEY' => 'test-api-key',
      'FRONTEND_URL' => 'https://app.example.com'
    ) do
      example.run
    end
  end

  let(:channel) { create(:channel_whatsapp_web) }
  let(:contact) { create(:contact, account: channel.account, name: 'Alice') }
  let(:contact_inbox) { create(:contact_inbox, inbox: channel.inbox, contact: contact, source_id: '15551234567') }
  let(:conversation) do
    create(
      :conversation,
      account: channel.account,
      inbox: channel.inbox,
      contact: contact,
      contact_inbox: contact_inbox
    )
  end
  let(:provisional_error) do
    "WhatsApp Web recipient is still a provisional @lid identity for conversation #{conversation.id}"
  end

  it 'retries only fresh provisional lid failures' do
    retryable_message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :failed,
      content_attributes: { external_error: provisional_error }
    )
    create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :failed,
      content_attributes: { external_error: 'Bad Request' }
    )
    stale_message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :failed,
      content_attributes: { external_error: provisional_error }
    )
    stale_message.update_columns(created_at: 10.minutes.ago, updated_at: 10.minutes.ago)

    clear_enqueued_jobs

    expect { service.perform }.to have_enqueued_job(SendReplyJob).with(retryable_message.id).on_queue('outbound_messages')

    expect(retryable_message.reload.status).to eq('sent')
    expect(retryable_message.external_error).to be_nil
    expect(
      retryable_message.content_attributes['whatsapp_web_provisional_lid_retry_attempted_at']
    ).to be_present
    expect(stale_message.reload.status).to eq('failed')
  end

  it 'does not retry the same message twice' do
    retryable_message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :failed,
      content_attributes: { external_error: provisional_error }
    )

    clear_enqueued_jobs
    service.perform
    clear_enqueued_jobs

    expect { service.perform }.not_to have_enqueued_job(SendReplyJob).with(retryable_message.id)
  end

  it 'does not retry messages superseded by a newer outbound reply' do
    superseded_message = create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :failed,
      content_attributes: { external_error: provisional_error }
    )
    create(
      :message,
      account: channel.account,
      inbox: channel.inbox,
      conversation: conversation,
      message_type: :outgoing,
      status: :sent,
      source_id: 'wamid.newer'
    )

    clear_enqueued_jobs

    expect { service.perform }.not_to have_enqueued_job(SendReplyJob).with(superseded_message.id)
    expect(superseded_message.reload.status).to eq('failed')
  end
end
