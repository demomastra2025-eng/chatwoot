require 'rails_helper'

RSpec.describe Channels::TelegramPersonal::ProcessWebhookEventJob do
  let(:channel) { create(:channel_telegram_personal) }

  def live_payload(peer_id, message_id)
    {
      'event' => 'message.created',
      'telegram_personal' => {
        'data' => { 'message_id' => message_id, 'chat_id' => peer_id, 'peer_user_id' => peer_id, 'sender_id' => peer_id,
                    'chat_type' => 'private', 'first_name' => 'Telegram', 'text' => 'Login code: 51234' }
      }
    }
  end

  it 'runs on the telegram_personal_inbound queue' do
    expect(described_class.queue_name).to eq('telegram_personal_inbound')
  end

  # The live path: a login code of the Telegram service account is left out, a person's message is taken in
  it 'takes in the live message of a person and leaves out the login code of the service account' do
    described_class.perform_now(channel.id, live_payload('777000', '601'))
    described_class.perform_now(channel.id, live_payload('23', '602'))

    expect(channel.inbox.messages.pluck(:source_id)).to eq(['602'])
    expect(channel.inbox.contact_inboxes.pluck(:source_id)).to eq(['23'])
  end
end
