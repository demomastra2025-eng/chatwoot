require 'rails_helper'

RSpec.describe Weixin::IncomingEventService do
  let(:channel) { create(:channel_weixin) }

  it 'applies runtime updates from the gateway' do
    pending_channel = Channel::Weixin.create!(account: create(:account), display_name: 'Pending QR Login')
    payload = {
      event: 'runtime.updated',
      weixin: {
        data: {
          connection_state: 'connected',
          lifecycle_state: 'connected',
          context_token: 'context-token-2',
          ilink_token: 'qr-issued-token',
          provider_account_id: 'wxid_qr_bot',
          display_name: 'QR Bot',
          runtime_state: { poller_state: 'running', last_update_id: 10 }
        }
      }
    }

    described_class.new(channel: pending_channel, payload: payload).perform
    channel = pending_channel.reload

    expect(channel.connection_state).to eq('connected')
    expect(channel.lifecycle_state).to eq('connected')
    expect(channel.context_token).to eq('context-token-2')
    expect(channel.ilink_token).to eq('qr-issued-token')
    expect(channel.token_fingerprint).to eq(Digest::SHA256.hexdigest('qr-issued-token'))
    expect(channel.provider_account_id).to eq('wxid_qr_bot')
    expect(channel.display_name).to eq('QR Bot')
    expect(channel.runtime_state['poller_state']).to eq('running')
  end

  it 'creates one incoming message and deduplicates repeated provider message ids' do
    payload = {
      event: 'message.created',
      weixin: {
        data: {
          message_id: 'wx-msg-1',
          sender_id: 'wxid_contact',
          sender_name: 'Alice',
          chat_id: 'wxid_contact',
          text: 'hello',
          context_token: 'message-context'
        }
      }
    }

    2.times { described_class.new(channel: channel, payload: payload).perform }

    inbox = channel.inbox
    contact_inbox = inbox.contact_inboxes.find_by!(source_id: 'wxid_contact')
    conversation = contact_inbox.conversations.last
    message = conversation.messages.find_by!(source_id: 'wx-msg-1')

    expect(inbox.messages.where(source_id: 'wx-msg-1').count).to eq(1)
    expect(contact_inbox.contact.name).to eq('Alice')
    expect(conversation.additional_attributes).to include('weixin_chat_id' => 'wxid_contact')
    expect(conversation.additional_attributes).not_to have_key('weixin_context_token')
    expect(channel.reload.context_token_for('wxid_contact')).to eq('message-context')
    expect(message.content).to eq('hello')
    expect(message.incoming?).to be(true)
  end
end
