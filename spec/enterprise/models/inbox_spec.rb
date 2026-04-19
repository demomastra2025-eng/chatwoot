# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox do
  let!(:inbox) { create(:inbox) }

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v22.0').and_return('v22.0')
  end

  describe 'member_ids_with_assignment_capacity' do
    let!(:inbox_member_1) { create(:inbox_member, inbox: inbox) }
    let!(:inbox_member_2) { create(:inbox_member, inbox: inbox) }
    let!(:inbox_member_3) { create(:inbox_member, inbox: inbox) }
    let!(:inbox_member_4) { create(:inbox_member, inbox: inbox) }

    before do
      create(:conversation, inbox: inbox, assignee: inbox_member_1.user)
      # to test conversations in other inboxes won't impact
      create_list(:conversation, 3, assignee: inbox_member_1.user)
      create_list(:conversation, 2, inbox: inbox, account: inbox.account, assignee: inbox_member_2.user)
      create_list(:conversation, 3, inbox: inbox, account: inbox.account, assignee: inbox_member_3.user)
    end

    it 'validated max_assignment_limit' do
      account = create(:account)
      expect(build(:inbox, account: account, auto_assignment_config: { max_assignment_limit: 0 })).not_to be_valid
      expect(build(:inbox, account: account, auto_assignment_config: {})).to be_valid
      expect(build(:inbox, account: account, auto_assignment_config: { max_assignment_limit: 1 })).to be_valid
    end

    it 'returns member ids with assignment capacity with inbox max_assignment_limit is configured' do
      # agent 1 has 1 conversations, agent 2 has 2 conversations, agent 3 has 3 conversations and agent 4 with none
      inbox.update(auto_assignment_config: { max_assignment_limit: 2 })
      expect(inbox.member_ids_with_assignment_capacity).to contain_exactly(inbox_member_1.user_id, inbox_member_4.user_id)
    end

    it 'returns all member ids when inbox max_assignment_limit is not configured' do
      expect(inbox.member_ids_with_assignment_capacity).to match_array(inbox.members.ids)
    end
  end

  describe 'audit log' do
    context 'when inbox is created' do
      it 'has associated audit log created' do
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'create').count).to eq(1)
      end
    end

    context 'when inbox is updated' do
      it 'has associated audit log created' do
        inbox.update(name: 'Updated Inbox')
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update').count).to eq(1)
      end
    end

    context 'when channel is updated' do
      it 'has associated audit log created' do
        previous_color = inbox.channel.widget_color
        new_color = '#ff0000'
        inbox.channel.update(widget_color: new_color)

        # check if channel update creates an audit log against inbox
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update').count).to eq(1)
        # Check for the specific widget_color update in the audit log
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update',
                                    audited_changes: { 'widget_color' => [previous_color, new_color] }).count).to eq(1)
      end
    end
  end

  describe 'audit log with api channel' do
    let!(:channel) { create(:channel_api) }
    let!(:inbox) { channel.inbox }

    context 'when inbox is created' do
      it 'has associated audit log created' do
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'create').count).to eq(1)
      end
    end

    context 'when inbox is updated' do
      it 'has associated audit log created' do
        inbox.update(name: 'Updated Inbox')
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update').count).to eq(1)
      end
    end

    context 'when channel is updated' do
      it 'has associated audit log created' do
        previous_webhook = inbox.channel.webhook_url
        new_webhook = 'https://example2.com'
        inbox.channel.update(webhook_url: new_webhook)

        # check if channel update creates an audit log against inbox
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update').count).to eq(1)
        # Check for the specific webhook_update update in the audit log
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update',
                                    audited_changes: { 'webhook_url' => [previous_webhook, new_webhook] }).count).to eq(1)
      end
    end
  end

  describe 'audit log with whatsapp channel' do
    let(:channel) { create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
    let(:inbox) { channel.inbox }

    before do
      stub_request(:get, 'https://graph.facebook.com/v22.0//message_templates')
        .to_return(status: 200, body: '', headers: {})
    end

    context 'when inbox is created' do
      it 'has associated audit log created' do
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'create').count).to eq(1)
      end
    end

    context 'when inbox is updated' do
      it 'has associated audit log created' do
        inbox.update(name: 'Updated Inbox')
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update').count).to eq(1)
      end
    end

    context 'when channel is updated' do
      it 'has associated audit log created' do
        previous_phone_number = inbox.channel.phone_number
        new_phone_number = '1234567890'
        inbox.channel.update(phone_number: new_phone_number)

        # check if channel update creates an audit log against inbox
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update').count).to eq(1)
        # Check for the specific phone_number update in the audit log
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update',
                                    audited_changes: { 'phone_number' => [previous_phone_number, new_phone_number] }).count).to eq(1)
      end
    end

    context 'when template sync runs' do
      it 'has no associated audit log created' do
        channel.sync_templates
        # check if template sync does not create an audit log
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update').count).to eq(0)
      end
    end
  end

  describe 'audit log with whatsapp web channel' do
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
    let(:inbox) { channel.inbox }

    context 'when only technical runtime fields are updated' do
      it 'does not create an audit log entry' do
        channel.update!(
          last_synced_at: Time.current,
          sync_state: channel.sync_state_payload.merge('last_incremental_sync_at' => Time.current.iso8601),
          connection_state: 'open',
          lifecycle_state: 'connected'
        )

        expect(Audited::Audit.where(auditable_type: 'Inbox', auditable_id: inbox.id, action: 'update').count).to eq(0)
      end
    end

    context 'when operator settings are updated alongside runtime fields' do
      it 'creates an audit log entry with only the meaningful settings changes' do
        previous_import_contacts = channel.import_contacts

        channel.update!(
          import_contacts: !previous_import_contacts,
          last_synced_at: Time.current,
          sync_state: channel.sync_state_payload.merge('last_incremental_sync_at' => Time.current.iso8601)
        )

        audit_log = Audited::Audit.where(auditable_type: 'Inbox', auditable_id: inbox.id, action: 'update').last

        expect(audit_log).to be_present
        expect(audit_log.audited_changes).to include('import_contacts' => [previous_import_contacts, !previous_import_contacts])
        expect(audit_log.audited_changes.keys).not_to include('last_synced_at', 'sync_state')
      end
    end
  end
end
