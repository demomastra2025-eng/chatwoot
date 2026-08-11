require 'rails_helper'

RSpec.describe 'Meta lead form webhooks', type: :request do
  let(:account) { create(:account) }
  let(:target_inbox) { create(:inbox, account: account) }
  let(:meta_channel) { create(:channel_instagram, account: account) }
  let!(:lead_form) do
    create(
      :lead_form,
      account: account,
      inbox: target_inbox,
      source_kind: 'meta',
      external_ref: 'meta-form-1',
      field_schema: [
        { 'name' => 'phone_number', 'label' => 'Phone number', 'type' => 'tel', 'required' => true }
      ],
      settings: {
        'verify_token' => 'lead-verify-token',
        'meta_connection_inbox_id' => meta_channel.inbox.id
      }
    )
  end

  it 'verifies the configured lead form token' do
    get '/webhooks/meta_lead_forms', params: {
      'hub.mode' => 'subscribe',
      'hub.verify_token' => 'lead-verify-token',
      'hub.challenge' => 'challenge-value'
    }

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('challenge-value')
  end

  it 'rejects unsigned event payloads when Meta app secret is configured' do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', nil).and_return('meta-secret')
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', nil).and_return(nil)
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', nil).and_return(nil)

    post '/webhooks/meta_lead_forms', params: webhook_body.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }

    expect(response).to have_http_status(:unauthorized)
  end

  it 'accepts signed event payloads' do
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', nil).and_return('meta-secret')
    allow(GlobalConfigService).to receive(:load).with('INSTAGRAM_APP_SECRET', nil).and_return(nil)
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', nil).and_return(nil)
    processor = instance_double(LeadForms::MetaProcessService, perform: true)
    allow(LeadForms::MetaProcessService).to receive(:new).and_return(processor)

    raw_body = webhook_body.to_json
    signature = OpenSSL::HMAC.hexdigest('SHA256', 'meta-secret', raw_body)

    post '/webhooks/meta_lead_forms',
         params: raw_body,
         headers: {
           'CONTENT_TYPE' => 'application/json',
           'X-Hub-Signature-256' => "sha256=#{signature}"
         }

    expect(response).to have_http_status(:ok)
    expect(LeadForms::MetaProcessService).to have_received(:new)
  end

  def webhook_body
    {
      object: 'page',
      entry: [
        {
          id: 'page-1',
          changes: [
            {
              field: 'leadgen',
              value: {
                form_id: lead_form.external_ref,
                leadgen_id: 'lead-1',
                page_id: 'page-1'
              }
            }
          ]
        }
      ]
    }
  end
end
