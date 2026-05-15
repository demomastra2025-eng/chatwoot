# frozen_string_literal: true

# rubocop:disable RSpec/DescribeClass
require 'rails_helper'

RSpec.describe 'Captain campaign copilot tools' do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:admin) { create(:user) }
  let(:agent) { create(:user) }
  let!(:admin_membership) { create(:account_user, account: account, user: admin, role: :administrator) }
  let!(:agent_membership) { create(:account_user, account: account, user: agent, role: :agent) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: admin, assistant: assistant) }
  let(:sms_inbox) { create(:inbox, account: account, channel: create(:channel_sms, account: account)) }
  let(:label) { create(:label, account: account, title: 'VIP') }
  let(:audience) { [{ type: 'Label', id: label.id }] }
  let(:audience_json) { audience.to_json }

  before do
    confirmation_gate = instance_double(Captain::Copilot::ToolConfirmationGate, call: nil)
    allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_return(confirmation_gate)
  end

  describe Captain::Tools::Copilot::ListCampaignsService do
    it 'lists only account campaigns and rejects non-admin direct execution' do
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience)
      create(:campaign, account: create(:account))

      payload = JSON.parse(described_class.new(assistant, user: admin).execute)

      expect(payload['total_count']).to eq(1)
      expect(payload['campaigns']).to contain_exactly(include('id' => campaign.display_id, 'title' => campaign.title))

      result = described_class.new(assistant, user: agent).execute
      expect(result).to include('Account administrator permission is required')
    end
  end

  describe Captain::Tools::Copilot::GetCampaignService do
    it 'returns one account campaign and rejects cross-account IDs' do
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, message: 'Hello')
      other = create(:campaign, account: create(:account))
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['action']).to eq('get_campaign')
      expect(payload.dig('campaign', 'id')).to eq(campaign.display_id)
      expect(payload.dig('campaign', 'message')).to eq('Hello')
      expect(service.execute(campaign_id: other.id)).to start_with('ERROR: ActiveRecord::RecordNotFound')
    end
  end

  describe Captain::Tools::Copilot::PreviewCampaignService do
    it 'previews with account-scoped inbox and requires admin' do
      contact = create(:contact, account: account, phone_number: '+1555010101')
      contact.label_list.add(label.title)
      contact.save!

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(
                             inbox_id: sms_inbox.id,
                             audience: audience,
                             message: 'Hello'
                           ))

      expect(payload['audience_size']).to eq(1)
      expect(payload['deliverable_count']).to eq(1)
      expect(described_class.new(assistant, user: agent).execute(inbox_id: sms_inbox.id, audience: audience)).to include(
        'Account administrator permission is required'
      )
    end
  end

  describe Captain::Tools::Copilot::CreateCampaignService do
    it 'creates an account campaign when confirmation is satisfied' do
      contact = create(:contact, account: account, phone_number: '+1555010102')
      contact.label_list.add(label.title)
      contact.save!
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(
                             title: 'VIP outbound',
                             inbox_id: sms_inbox.id,
                             audience_json: audience_json,
                             message: 'Hello VIP',
                             scheduled_at: 1.hour.from_now.iso8601
                           ))

      expect(payload['action']).to eq('create_campaign')
      expect(payload.dig('campaign', 'title')).to eq('VIP outbound')
      expect(payload.dig('campaign', 'campaign_type')).to eq('one_off')
      expect(account.campaigns.find_by(title: 'VIP outbound')).to be_present
    end

    it 'does not create without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(
                             title: 'Blocked outbound',
                             inbox_id: sms_inbox.id,
                             audience_json: audience_json,
                             message: 'Blocked'
                           ))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.campaigns.find_by(title: 'Blocked outbound')).to be_nil
    end

    it 'rejects cross-account sender and inbox IDs' do
      other_account = create(:account)
      other_inbox = create(:inbox, account: other_account)
      other_user = create(:user, :administrator, account: other_account)
      service = described_class.new(assistant, user: admin)

      expect(service.execute(title: 'Bad inbox', inbox_id: other_inbox.id, audience_json: audience_json, message: 'Hi')).to start_with(
        'ERROR: ActiveRecord::RecordNotFound'
      )
      expect(service.execute(title: 'Bad sender', inbox_id: sms_inbox.id, audience_json: audience_json, message: 'Hi', sender_id: other_user.id)).to start_with(
        'ERROR: ActiveRecord::RecordNotFound'
      )
    end
  end

  describe Captain::Tools::Copilot::UpdateCampaignService do
    it 'updates account campaigns and rejects non-admin direct execution' do
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, message: 'Old')
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id, title: 'Updated', message: 'New'))

      expect(payload['action']).to eq('update_campaign')
      expect(campaign.reload).to have_attributes(title: 'Updated', message: 'New')
      expect(described_class.new(assistant, user: agent).execute(campaign_id: campaign.display_id, message: 'Nope')).to include(
        'Account administrator permission is required'
      )
    end

    it 'does not update without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, message: 'Safe')
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id, message: 'Unsafe'))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(campaign.reload.message).to eq('Safe')
    end
  end

  describe Captain::Tools::Copilot::DeleteCampaignService do
    it 'deletes account campaigns and rejects running campaigns' do
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience)
      running = create(:campaign, account: account, inbox: sms_inbox, audience: audience, campaign_status: :running)
      service = described_class.new(assistant, user: admin)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['action']).to eq('delete_campaign')
      expect(account.campaigns.exists?(campaign.id)).to be(false)
      expect(service.execute(campaign_id: running.display_id)).to include('Running campaigns must be cancelled before deletion')
    end

    it 'does not delete without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(account.campaigns.exists?(campaign.id)).to be(true)
    end
  end

  describe Captain::Tools::Copilot::LaunchCampaignService do
    it 'queues active one-off campaigns after preview safety checks' do
      contact = create(:contact, account: account, phone_number: '+1555010103')
      contact.label_list.add(label.title)
      contact.save!
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, message: 'Launch me')
      allow(Campaigns::TriggerOneoffCampaignJob).to receive(:perform_later)

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(campaign_id: campaign.display_id))

      expect(payload['action']).to eq('launch_campaign')
      expect(payload['queued']).to be(true)
      expect(Campaigns::TriggerOneoffCampaignJob).to have_received(:perform_later).with(campaign)
    end

    it 'does not enqueue without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, message: 'Safe')
      allow(Campaigns::TriggerOneoffCampaignJob).to receive(:perform_later)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(Campaigns::TriggerOneoffCampaignJob).not_to have_received(:perform_later)
    end
  end

  describe Captain::Tools::Copilot::CancelCampaignService do
    it 'cancels one-off campaigns' do
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience)

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(campaign_id: campaign.display_id))

      expect(payload['action']).to eq('cancel_campaign')
      expect(campaign.reload.cancelled?).to be(true)
    end

    it 'does not cancel without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(campaign.reload.active?).to be(true)
    end
  end

  describe Captain::Tools::Copilot::RestartCampaignService do
    it 'delegates to native restart service' do
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, campaign_status: :failed)
      create(:campaign_run, account: account, campaign: campaign, inbox: sms_inbox, status: :failed)
      restart_service = instance_double(Campaigns::RestartService, perform: true)
      allow(Campaigns::RestartService).to receive(:new).and_return(restart_service)
      allow(Campaigns::AnalyticsService).to receive(:new).and_return(instance_double(Campaigns::AnalyticsService, call: { restarted: true }))

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(campaign_id: campaign.display_id))

      expect(payload['action']).to eq('restart_campaign')
      expect(restart_service).to have_received(:perform)
      expect(payload['analytics']).to eq('restarted' => true)
    end

    it 'does not restart without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, campaign_status: :failed)
      restart_service = instance_double(Campaigns::RestartService, perform: true)
      allow(Campaigns::RestartService).to receive(:new).and_return(restart_service)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(Campaigns::RestartService).not_to have_received(:new)
    end
  end

  describe Captain::Tools::Copilot::ResumeCampaignService do
    it 'delegates to native resume service' do
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, campaign_status: :failed)
      create(:campaign_run, account: account, campaign: campaign, inbox: sms_inbox, status: :failed)
      resume_service = instance_double(Campaigns::ResumeService, perform: true)
      allow(Campaigns::ResumeService).to receive(:new).and_return(resume_service)
      allow(Campaigns::AnalyticsService).to receive(:new).and_return(instance_double(Campaigns::AnalyticsService, call: { resumed: true }))

      payload = JSON.parse(described_class.new(assistant, user: admin).execute(campaign_id: campaign.display_id))

      expect(payload['action']).to eq('resume_campaign')
      expect(resume_service).to have_received(:perform)
      expect(payload['analytics']).to eq('resumed' => true)
    end

    it 'does not resume without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, campaign_status: :failed)
      resume_service = instance_double(Campaigns::ResumeService, perform: true)
      allow(Campaigns::ResumeService).to receive(:new).and_return(resume_service)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(Campaigns::ResumeService).not_to have_received(:new)
    end
  end

  describe Captain::Tools::Copilot::RetryFailedCampaignDeliveriesService do
    it 'does not retry without backend confirmation' do
      allow(Captain::Copilot::ToolConfirmationGate).to receive(:new).and_call_original
      campaign = create(:campaign, account: account, inbox: sms_inbox, audience: audience, campaign_status: :failed)
      retry_service = instance_double(Campaigns::RetryFailedDeliveriesService, perform: true)
      allow(Campaigns::RetryFailedDeliveriesService).to receive(:new).and_return(retry_service)
      service = described_class.new(assistant, user: admin, copilot_thread: copilot_thread)

      payload = JSON.parse(service.execute(campaign_id: campaign.display_id))

      expect(payload['message']).to include('Operator confirmation is required')
      expect(Campaigns::RetryFailedDeliveriesService).not_to have_received(:new)
    end
  end

  describe 'campaign tool registry metadata' do
    it 'keeps campaign tools assistant-only and marks dangerous tools high-risk confirmation-only' do
      agent_tool_ids = Captain::ToolRegistry.tools_for_scope(Captain::ToolAccess::SCOPE_AGENT).pluck(:id)
      campaign_tool_ids = %w[
        list_campaigns get_campaign preview_campaign get_campaign_analytics create_campaign update_campaign delete_campaign
        launch_campaign cancel_campaign restart_campaign resume_campaign retry_failed_campaign_deliveries
      ]
      high_risk_tool_ids = campaign_tool_ids - %w[list_campaigns get_campaign preview_campaign get_campaign_analytics]

      expect(agent_tool_ids).not_to include(*campaign_tool_ids)

      campaign_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.allowed_scopes).to eq([Captain::ToolAccess::SCOPE_ASSISTANT])
      end

      high_risk_tool_ids.each do |tool_id|
        definition = Captain::ToolRegistry.definition_for(tool_id)
        expect(definition.risk_level).to eq('high')
        expect(definition.requires_confirmation).to be(true)
        expect(definition.to_h[:selected_by_default]).to be(false)
      end
    end
  end
end
# rubocop:enable RSpec/DescribeClass
