require 'rails_helper'

RSpec.describe 'Campaigns API', type: :request do
  let(:account) { create(:account) }

  describe 'GET /api/v1/accounts/{account.id}/campaigns' do
    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/campaigns"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }
      let(:inbox) { create(:inbox, account: account) }
      let!(:campaign) { create(:campaign, account: account, inbox: inbox, trigger_rules: { url: 'https://test.com' }) }

      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/campaigns",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'returns all campaigns to administrators' do
        get "/api/v1/accounts/#{account.id}/campaigns",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)
        expect(body.first[:id]).to eq(campaign.display_id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/campaigns/:id' do
    let(:campaign) { create(:campaign, account: account, trigger_rules: { url: 'https://test.com' }) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}"

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'returns unauthorized for agents' do
        get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
            headers: agent.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'shows the campaign for administrators' do
        get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
            headers: administrator.create_new_auth_token,
            as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:id]).to eq(campaign.display_id)
      end
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/campaigns/:id/analytics' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:inbox) { create(:inbox, account: account) }
    let!(:campaign) { create(:campaign, account: account, inbox: inbox) }
    let!(:delivered_delivery) do
      create(:campaign_delivery, campaign: campaign, account: account, inbox: inbox, status: 'delivered', provider: 'twilio_sms')
    end
    let!(:failed_delivery) do
      create(
        :campaign_delivery,
        campaign: campaign,
        account: account,
        inbox: inbox,
        status: 'failed',
        provider: 'twilio_sms',
        error_message: '30008 - Unknown error'
      )
    end

    it 'returns native delivery analytics for one-off campaigns' do
      get "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/analytics",
          headers: administrator.create_new_auth_token,
          as: :json

      expect(response).to have_http_status(:success)

      body = JSON.parse(response.body, symbolize_names: true)

      expect(body[:audience_size]).to eq(2)
      expect(body[:totals][:delivered]).to eq(1)
      expect(body[:totals][:failed]).to eq(1)
      expect(body[:errors].first[:message]).to eq('30008 - Unknown error')
      expect(body[:deliveries].pluck(:status)).to include('delivered', 'failed')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns/:id/retry_failed' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:channel) { create(:channel_email, account: account) }
    let(:campaign) { create(:campaign, account: account, inbox: channel.inbox) }

    it 'returns unauthorized for agents' do
      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/retry_failed",
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'retries failed deliveries for administrators' do
      retried_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :completed)
      analytics_payload = {
        campaign_id: campaign.display_id,
        campaign_status: 'completed',
        latest_run: { id: retried_run.id, status: 'completed' },
        recent_runs: [{ id: retried_run.id, status: 'completed' }],
        totals: {},
        errors: [],
        deliveries: [],
        not_sent_contacts: [],
        audience_size: 0,
        deliveries_count: 0,
        not_sent_count: 0,
        coverage_rate: 0,
        success_rate: 0
      }

      retry_service = instance_double(Campaigns::RetryFailedDeliveriesService, perform: retried_run)
      analytics_service = instance_double(Campaigns::AnalyticsService, call: analytics_payload)

      expect(Campaigns::RetryFailedDeliveriesService).to receive(:new).with(campaign: campaign).and_return(retry_service)
      expect(Campaigns::AnalyticsService).to receive(:new).with(campaign: campaign).and_return(analytics_service)

      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/retry_failed",
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body, symbolize_names: true)[:latest_run][:id]).to eq(retried_run.id)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns/:id/cancel' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:channel) { create(:channel_email, account: account) }
    let(:campaign) { create(:campaign, account: account, inbox: channel.inbox, campaign_status: :active) }

    it 'returns unauthorized for agents' do
      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/cancel",
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'cancels one-off campaigns for administrators' do
      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/cancel",
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body, symbolize_names: true)[:campaign_status]).to eq('cancelled')
      expect(campaign.reload.cancelled?).to be(true)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns/:id/restart' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:channel) { create(:channel_email, account: account) }
    let(:campaign) { create(:campaign, account: account, inbox: channel.inbox, campaign_status: :failed) }

    it 'returns unauthorized for agents' do
      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/restart",
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'restarts the campaign for administrators' do
      restarted_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :running)
      analytics_payload = {
        campaign_id: campaign.display_id,
        campaign_status: 'running',
        latest_run: { id: restarted_run.id, status: 'running' },
        recent_runs: [{ id: restarted_run.id, status: 'running' }],
        totals: {},
        errors: [],
        deliveries: [],
        not_sent_contacts: [],
        audience_size: 0,
        deliveries_count: 0,
        not_sent_count: 0,
        coverage_rate: 0,
        success_rate: 0
      }

      restart_service = instance_double(Campaigns::RestartService, perform: restarted_run)
      analytics_service = instance_double(Campaigns::AnalyticsService, call: analytics_payload)

      expect(Campaigns::RestartService).to receive(:new).with(campaign: campaign).and_return(restart_service)
      expect(Campaigns::AnalyticsService).to receive(:new).with(campaign: campaign).and_return(analytics_service)

      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/restart",
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body, symbolize_names: true)[:latest_run][:id]).to eq(restarted_run.id)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns/:id/resume' do
    let(:administrator) { create(:user, account: account, role: :administrator) }
    let(:agent) { create(:user, account: account, role: :agent) }
    let(:channel) { create(:channel_email, account: account) }
    let(:campaign) { create(:campaign, account: account, inbox: channel.inbox, campaign_status: :cancelled) }

    it 'returns unauthorized for agents' do
      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/resume",
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'resumes the campaign for administrators' do
      resumed_run = create(:campaign_run, campaign: campaign, account: account, inbox: campaign.inbox, status: :running)
      analytics_payload = {
        campaign_id: campaign.display_id,
        campaign_status: 'running',
        latest_run: { id: resumed_run.id, status: 'running', resumable_contacts_count: 0 },
        recent_runs: [{ id: resumed_run.id, status: 'running' }],
        totals: {},
        errors: [],
        deliveries: [],
        not_sent_contacts: [],
        audience_size: 0,
        deliveries_count: 0,
        not_sent_count: 0,
        coverage_rate: 0,
        success_rate: 0
      }

      resume_service = instance_double(Campaigns::ResumeService, perform: resumed_run)
      analytics_service = instance_double(Campaigns::AnalyticsService, call: analytics_payload)

      expect(Campaigns::ResumeService).to receive(:new).with(campaign: campaign).and_return(resume_service)
      expect(Campaigns::AnalyticsService).to receive(:new).with(campaign: campaign).and_return(analytics_service)

      post "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}/resume",
           headers: administrator.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(JSON.parse(response.body, symbolize_names: true)[:latest_run][:id]).to eq(resumed_run.id)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns' do
    let(:inbox) { create(:inbox, account: account) }

    it 'atomically claims a completed file audience for the matching account and inbox' do
      administrator = create(:user, account: account, role: :administrator)
      headers = administrator.create_new_auth_token
      sms_inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))
      audience_import = create(:campaign_audience_import, account: account, inbox: sms_inbox)
      contact = create(:contact, account: account, phone_number: '+77051234567')
      create(
        :campaign_audience_recipient,
        campaign_audience_import: audience_import,
        account: account,
        contact: contact,
        normalized_phone_number: contact.phone_number
      )
      params = {
        title: 'File audience campaign',
        message: 'Hello',
        inbox_id: sms_inbox.id,
        scheduled_at: 1.hour.from_now.iso8601,
        audience: [],
        audience_import_token: audience_import.token
      }

      post "/api/v1/accounts/#{account.id}/campaigns", params: params, headers: headers, as: :json

      expect(response).to have_http_status(:success)
      campaign = account.campaigns.order(:id).last
      expect(campaign.campaign_audience_import).to eq(audience_import)
      expect(audience_import.reload.claimed_at).to be_present

      expect do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: params.merge(title: 'Reuse'), headers: headers, as: :json
      end.not_to change(Campaign, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it 'rejects file audiences from another inbox without claiming them' do
      administrator = create(:user, account: account, role: :administrator)
      sms_inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))
      audience_import = create(:campaign_audience_import, account: account, inbox: sms_inbox)

      expect do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: {
               title: 'Wrong inbox', message: 'Hello', inbox_id: inbox.id, scheduled_at: 1.hour.from_now.iso8601,
               audience: [], audience_import_token: audience_import.token
             },
             headers: administrator.create_new_auth_token,
             as: :json
      end.not_to change(Campaign, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(audience_import.reload.claimed_at).to be_nil
    end

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'returns unauthorized for agents' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
             headers: agent.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'creates a new campaign' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:title]).to eq('test')
      end

      it 'defaults the campaign sender to the authenticated creator when sender_id is omitted' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)

        response_data = JSON.parse(response.body, symbolize_names: true)
        campaign = Campaign.find_by!(display_id: response_data[:id])

        expect(campaign.sender).to eq(administrator)
        expect(response_data.dig(:sender, :id)).to eq(administrator.id)
      end

      it 'preserves an explicitly selected campaign sender' do
        selected_sender = create(:user, account: account, role: :agent)

        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message', sender_id: selected_sender.id },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)

        response_data = JSON.parse(response.body, symbolize_names: true)
        campaign = Campaign.find_by!(display_id: response_data[:id])

        expect(campaign.sender).to eq(selected_sender)
        expect(response_data.dig(:sender, :id)).to eq(selected_sender.id)
      end

      it 'preserves an explicitly blank campaign sender for bot-authored campaigns' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message', sender_id: nil },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)

        response_data = JSON.parse(response.body, symbolize_names: true)
        campaign = Campaign.find_by!(display_id: response_data[:id])

        expect(campaign.sender).to be_nil
        expect(response_data[:sender]).to be_blank
      end

      it 'rejects a campaign sender from another account' do
        external_sender = create(:user, account: create(:account), role: :agent)

        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message', sender_id: external_sender.id },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(Campaign.where(account: account, title: 'test')).to be_empty
      end

      it 'serializes the configured AI agent for AI-authored scheduled campaigns' do
        email_channel = create(:channel_email, account: account)
        assistant = create(:captain_assistant, account: account, name: 'Sales AI')
        create(:captain_inbox, inbox: email_channel.inbox, captain_assistant: assistant)

        post "/api/v1/accounts/#{account.id}/campaigns",
             params: {
               inbox_id: email_channel.inbox.id,
               title: 'AI follow-up',
               message: '',
               instructions: 'Write a short follow-up',
               text_mode: 'agent',
               scheduled_at: 1.day.from_now
             },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)

        response_data = JSON.parse(response.body, symbolize_names: true)
        campaign = Campaign.find_by!(display_id: response_data[:id])

        expect(campaign.captain_assistant).to eq(assistant)
        expect(response_data[:text_mode]).to eq('agent')
        expect(response_data.dig(:ai_sender, :type)).to eq('captain_assistant')
        expect(response_data.dig(:ai_sender, :id)).to eq(assistant.id)
        expect(response_data.dig(:ai_sender, :name)).to eq('Sales AI')
      end

      it 'rejects an explicitly provided AI agent from another account' do
        email_channel = create(:channel_email, account: account)
        create(:captain_inbox, inbox: email_channel.inbox, captain_assistant: create(:captain_assistant, account: account))
        external_assistant = create(:captain_assistant, account: create(:account), name: 'External AI')

        post "/api/v1/accounts/#{account.id}/campaigns",
             params: {
               inbox_id: email_channel.inbox.id,
               title: 'AI follow-up',
               message: '',
               instructions: 'Write a short follow-up',
               text_mode: 'agent',
               captain_assistant_id: external_assistant.id,
               scheduled_at: 1.day.from_now
             },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(Campaign.where(account: account, title: 'AI follow-up')).to be_empty
      end

      it 'rejects an explicitly provided AI agent that is not configured for the selected inbox' do
        email_channel = create(:channel_email, account: account)
        create(:captain_inbox, inbox: email_channel.inbox, captain_assistant: create(:captain_assistant, account: account))
        other_assistant = create(:captain_assistant, account: account, name: 'Other AI')

        post "/api/v1/accounts/#{account.id}/campaigns",
             params: {
               inbox_id: email_channel.inbox.id,
               title: 'AI follow-up',
               message: '',
               instructions: 'Write a short follow-up',
               text_mode: 'agent',
               captain_assistant_id: other_assistant.id,
               scheduled_at: 1.day.from_now
             },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
        expect(Campaign.where(account: account, title: 'AI follow-up')).to be_empty
      end

      it 'creates a new ongoing campaign' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message', trigger_rules: { url: 'https://test.com' } },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:title]).to eq('test')
      end

      it 'throws error when invalid url provided for ongoing campaign' do
        post "/api/v1/accounts/#{account.id}/campaigns",
             params: { inbox_id: inbox.id, title: 'test', message: 'test message', trigger_rules: { url: 'javascript' } },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end

      it 'creates a new oneoff campaign' do
        twilio_sms = create(:channel_twilio_sms, account: account)
        twilio_inbox = create(:inbox, channel: twilio_sms, account: account)
        label1 = create(:label, account: account)
        label2 = create(:label, account: account)
        scheduled_at = 2.days.from_now

        post "/api/v1/accounts/#{account.id}/campaigns",
             params: {
               inbox_id: twilio_inbox.id, title: 'test', message: 'test message',
               scheduled_at: scheduled_at,
               audience: [{ type: 'Label', id: label1.id }, { type: 'Label', id: label2.id }]
             },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        response_data = JSON.parse(response.body, symbolize_names: true)
        expect(response_data[:campaign_type]).to eq('one_off')
        expect(response_data[:scheduled_at].present?).to be true
        expect(response_data[:scheduled_at]).to eq(scheduled_at.to_i)
        expect(response_data[:audience].pluck(:id)).to include(label1.id, label2.id)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/campaigns/preview' do
    let(:administrator) { create(:user, account: account, role: :administrator) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        post "/api/v1/accounts/#{account.id}/campaigns/preview",
             params: { inbox_id: create(:inbox, account: account).id, audience: [] },
             as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated administrator' do
      it 'returns preview data for a supported inbox' do
        inbox = create(:inbox, account: account, channel: create(:channel_sms, account: account))
        label = create(:label, account: account, title: 'Priority')
        contact = create(:contact, account: account, phone_number: '+15550001114')
        contact.label_list.add(label.title)
        contact.save!

        post "/api/v1/accounts/#{account.id}/campaigns/preview",
             params: {
               inbox_id: inbox.id,
               title: 'test',
               message: 'test message',
               audience: [{ type: 'Label', id: label.id }]
             },
             headers: administrator.create_new_auth_token,
             as: :json

        expect(response).to have_http_status(:success)
        body = JSON.parse(response.body, symbolize_names: true)

        expect(body[:audience_size]).to eq(1)
        expect(body[:deliverable_count]).to eq(1)
        expect(body.dig(:capabilities, :delivery_readiness)).to eq('ready')
        expect(body.dig(:totals, :deliverable)).to eq(1)
      end
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/campaigns/:id' do
    let(:inbox) { create(:inbox, account: account) }
    let!(:campaign) { create(:campaign, account: account, trigger_rules: { url: 'https://test.com' }) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        patch "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
              params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'returns unauthorized for agents' do
        patch "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
              params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
              headers: agent.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'updates the campaign' do
        patch "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
              params: { inbox_id: inbox.id, title: 'test', message: 'test message' },
              headers: administrator.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(JSON.parse(response.body, symbolize_names: true)[:title]).to eq('test')
      end

      it 'does not overwrite the existing sender when update omits sender_id' do
        selected_sender = create(:user, account: account, role: :agent)
        campaign.update!(sender: selected_sender)

        patch "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
              params: { inbox_id: inbox.id, title: 'updated', message: 'updated message' },
              headers: administrator.create_new_auth_token,
              as: :json

        expect(response).to have_http_status(:success)
        expect(campaign.reload.sender).to eq(selected_sender)
      end
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/campaigns/:id' do
    let(:inbox) { create(:inbox, account: account) }
    let!(:campaign) { create(:campaign, account: account, trigger_rules: { url: 'https://test.com' }) }

    context 'when it is an unauthenticated user' do
      it 'returns unauthorized' do
        delete "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context 'when it is an authenticated user' do
      let(:agent) { create(:user, account: account, role: :agent) }
      let(:administrator) { create(:user, account: account, role: :administrator) }

      it 'return unauthorized if agent' do
        delete "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
               headers: agent.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:unauthorized)
      end

      it 'delete campaign if admin' do
        delete "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
               headers: administrator.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(Campaign.exists?(campaign.display_id)).to be false
      end

      it 'deletes campaign with campaign deliveries if admin' do
        create(
          :campaign_delivery,
          campaign: campaign,
          account: account,
          inbox: campaign.inbox,
          provider: 'test_provider',
          status: 'delivered'
        )

        delete "/api/v1/accounts/#{account.id}/campaigns/#{campaign.display_id}",
               headers: administrator.create_new_auth_token,
               as: :json

        expect(response).to have_http_status(:success)
        expect(Campaign.exists?(campaign.id)).to be false
        expect(CampaignDelivery.where(campaign_id: campaign.id)).to be_empty
      end
    end
  end
end
