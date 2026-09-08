require 'rails_helper'

RSpec.describe Api::V1::Accounts::InboxesController, type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }

  %w[Whatsapp TelegramPersonal Weixin VkCommunity Sms Line TwilioSms Voice].each do |channel_name|
    it "renders the list and show page when a #{channel_name} channel row is missing" do
      orphan = create(:inbox, account: account, name: 'A orphan')
      healthy = create(:inbox, account: account, name: 'Z healthy')
      # Reproduce a broken polymorphic reference without contacting a provider.
      orphan.update_columns(channel_type: "Channel::#{channel_name}", channel_id: -1) # rubocop:disable Rails/SkipsModelValidations

      get "/api/v1/accounts/#{account.id}/inboxes", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      rows = response.parsed_body['payload']
      expect(rows.pluck('id')).to include(orphan.id, healthy.id)
      row = rows.find { |item| item['id'] == orphan.id }
      expect(row['callback_webhook_url']).to be_nil
      expect(row.dig('campaign_capabilities', 'supports_outbound_campaigns')).to be(false)
      expect(row.dig('campaign_capabilities', 'delivery_readiness')).to eq('unsupported')

      get "/api/v1/accounts/#{account.id}/inboxes/#{orphan.id}", headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['id']).to eq(orphan.id)
    end
  end
end
