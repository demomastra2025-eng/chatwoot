require 'rails_helper'

RSpec.describe 'Inboxes whose channel record is missing', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let!(:healthy_inbox) { create(:inbox, account: account, name: 'Healthy web widget') }

  channel_types = %w[
    Channel::Api Channel::Email Channel::FacebookPage Channel::Instagram Channel::Line Channel::Sms
    Channel::Telegram Channel::TelegramPersonal Channel::Tiktok Channel::TwilioSms Channel::TwitterProfile
    Channel::VkCommunity Channel::Voice Channel::WebWidget Channel::Weixin Channel::Whatsapp Channel::WhatsappWeb
  ].freeze

  # Legacy data: the inbox row survived while its channel row was deleted underneath it.
  def orphan_inbox(channel_type)
    inbox = create(:inbox, account: account, name: "Orphan #{channel_type.demodulize}")
    missing_channel_id = channel_type.constantize.maximum(:id).to_i + 1_000_000
    inbox.update_columns(channel_type: channel_type, channel_id: missing_channel_id) # rubocop:disable Rails/SkipsModelValidations
    inbox.reload
  end

  it 'lists every inbox and marks each one whose channel record is gone' do
    orphans = channel_types.map { |channel_type| orphan_inbox(channel_type) }

    with_modified_env('FRONTEND_URL' => 'https://app.example.test') do
      get "/api/v1/accounts/#{account.id}/inboxes", headers: admin.create_new_auth_token, as: :json
    end

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.fetch('payload').index_by { |item| item['id'] }
    expect(payload.keys).to contain_exactly(healthy_inbox.id, *orphans.map(&:id))
    expect(payload.fetch(healthy_inbox.id)).to include('channel_missing' => false, 'name' => 'Healthy web widget')
    orphans.each do |inbox|
      expect(payload.fetch(inbox.id)).to include(
        'name' => inbox.name,
        'channel_missing' => true,
        'callback_webhook_url' => nil
      )
    end
  end

  it 'renders a single inbox whose channel record is gone' do
    orphan = orphan_inbox('Channel::Whatsapp')

    get "/api/v1/accounts/#{account.id}/inboxes/#{orphan.id}", headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('id' => orphan.id, 'channel_type' => 'Channel::Whatsapp', 'channel_missing' => true)
  end

  it 'lets an administrator delete an inbox whose channel record is gone' do
    orphan = orphan_inbox('Channel::Whatsapp')

    delete "/api/v1/accounts/#{account.id}/inboxes/#{orphan.id}", headers: admin.create_new_auth_token, as: :json

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include('id' => orphan.id, 'deleting' => true)
    expect(DeleteObjectJob).to have_been_enqueued.with(orphan, admin, anything)

    perform_enqueued_jobs(only: DeleteObjectJob)

    expect(Inbox.exists?(orphan.id)).to be(false)
    expect(Inbox.exists?(healthy_inbox.id)).to be(true)
  end
end
