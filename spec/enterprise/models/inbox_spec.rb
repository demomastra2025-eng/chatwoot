# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Inbox do
  let!(:inbox) { create(:inbox) }

  def inbox_update_audits
    Audited::Audit.where(auditable_type: 'Inbox', auditable_id: inbox.id, action: 'update')
  end

  before do
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_API_VERSION', 'v25.0').and_return('v22.0')
  end

  describe 'workspace channel limits' do
    let(:account) { create(:account, limits: { call_inboxes: 1 }) }

    it 'applies the call-channel limit without counting messaging channels' do
      create(:inbox, account: account)

      expect(build(:inbox, account: account, channel: build(:channel_voice, :sipuni, account: account))).to be_valid
      create(:channel_voice, :sipuni, account: account)
      expect(build(:inbox, account: account, channel: build(:channel_voice, :sipuni, account: account))).not_to be_valid
    end

    it 'blocks call channels when the account-level call limit is zero' do
      account.update!(limits: { call_inboxes: 0 })

      limited_inbox = build(:inbox, account: account, channel: build(:channel_voice, :sipuni, account: account))

      expect(limited_inbox).not_to be_valid
      expect(limited_inbox.errors[:base]).to include('Account call channel limit exceeded')
    end

    it 'blocks call channels when the global call limit is zero' do
      account.update!(limits: {})
      InstallationConfig.find_or_initialize_by(name: 'ACCOUNT_CALL_INBOXES_LIMIT').update!(value: 0, locked: false)
      GlobalConfig.clear_cache

      limited_inbox = build(:inbox, account: account, channel: build(:channel_voice, :sipuni, account: account))

      expect(limited_inbox).not_to be_valid
      expect(limited_inbox.errors[:base]).to include('Account call channel limit exceeded')
    ensure
      GlobalConfig.clear_cache
    end

    it 'enforces the messaging-channel limit for direct model creation' do
      account.update!(limits: { inboxes: 1, call_inboxes: 1 })
      create(:inbox, account: account)

      expect(build(:inbox, account: account)).not_to be_valid
      expect(build(:inbox, account: account, channel: build(:channel_voice, :sipuni, account: account))).to be_valid
    end

    it 'continues enforcing the legacy main-channel limit independently' do
      account.update!(limits: { inboxes: 10, call_inboxes: 1, non_web_inboxes: 1 })
      create(:inbox, account: account, channel: build(:channel_api, account: account))

      limited_inbox = build(:inbox, account: account, channel: build(:channel_api, account: account))

      expect(limited_inbox).not_to be_valid
      expect(limited_inbox.errors[:base]).to include('Account main channel limit exceeded')
      expect(build(:inbox, account: account)).to be_valid
    end
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

  describe 'member_ids_with_assignment_capacity with V2 capacity' do
    let(:account) { create(:account) }
    let(:v2_inbox) { create(:inbox, account: account, enable_auto_assignment: true) }
    let(:agent_capacity_policy) { create(:agent_capacity_policy, account: account) }

    let!(:agent1) { create(:user, account: account, role: :agent, auto_offline: false) }
    let!(:agent2) { create(:user, account: account, role: :agent, auto_offline: false) }

    before do
      create(:inbox_member, inbox: v2_inbox, user: agent1)
      create(:inbox_member, inbox: v2_inbox, user: agent2)

      allow(OnlineStatusTracker).to receive(:get_available_users).and_return(
        agent1.id.to_s => 'online',
        agent2.id.to_s => 'online'
      )
    end

    context 'when assignment_v2 is enabled with capacity policies' do
      before do
        account.enable_features('assignment_v2', 'advanced_assignment')
        account.save!

        create(:inbox_capacity_limit, agent_capacity_policy: agent_capacity_policy, inbox: v2_inbox, conversation_limit: 1)
        agent1.account_users.find_by(account: account).update!(agent_capacity_policy: agent_capacity_policy)
        agent2.account_users.find_by(account: account).update!(agent_capacity_policy: agent_capacity_policy)
      end

      it 'filters out agents at capacity' do
        create(:conversation, inbox: v2_inbox, account: account, assignee: agent1, status: :open)

        result = v2_inbox.member_ids_with_assignment_capacity
        expect(result).to include(agent2.id)
        expect(result).not_to include(agent1.id)
      end

      it 'filters out all agents when all are at capacity' do
        create(:conversation, inbox: v2_inbox, account: account, assignee: agent1, status: :open)
        create(:conversation, inbox: v2_inbox, account: account, assignee: agent2, status: :open)

        expect(v2_inbox.member_ids_with_assignment_capacity).to be_empty
      end

      it 'skips V1 max_assignment_limit when V2 is enabled' do
        v2_inbox.update(auto_assignment_config: { max_assignment_limit: 100 })

        create(:conversation, inbox: v2_inbox, account: account, assignee: agent1, status: :open)

        result = v2_inbox.member_ids_with_assignment_capacity
        expect(result).not_to include(agent1.id)
      end
    end

    context 'when assignment_v2 is enabled without capacity policies' do
      before do
        account.enable_features('assignment_v2', 'advanced_assignment')
        account.save!
      end

      it 'returns all online agents' do
        result = v2_inbox.member_ids_with_assignment_capacity
        expect(result).to contain_exactly(agent1.id, agent2.id)
      end
    end

    context 'when advanced_assignment is disabled (downgraded account with stale policies)' do
      before do
        account.enable_features('assignment_v2')
        account.save!

        create(:inbox_capacity_limit, agent_capacity_policy: agent_capacity_policy, inbox: v2_inbox, conversation_limit: 1)
        agent1.account_users.find_by(account: account).update!(agent_capacity_policy: agent_capacity_policy)

        create(:conversation, inbox: v2_inbox, account: account, assignee: agent1, status: :open)
      end

      it 'does not enforce capacity limits' do
        result = v2_inbox.member_ids_with_assignment_capacity
        expect(result).to include(agent1.id)
      end
    end

    context 'when assignment_v2 is disabled (V1 path)' do
      before do
        v2_inbox.update(auto_assignment_config: { max_assignment_limit: 2 })
      end

      it 'uses V1 max_assignment_limit' do
        create_list(:conversation, 2, inbox: v2_inbox, account: account, assignee: agent1, status: :open)

        result = v2_inbox.member_ids_with_assignment_capacity
        expect(result).not_to include(agent1.id)
        expect(result).to include(agent2.id)
      end
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
        expect { inbox.update!(name: 'Updated Inbox') }.to change(inbox_update_audits, :count).by(1)
      end
    end

    context 'when channel is updated' do
      it 'has associated audit log created' do
        previous_color = inbox.channel.widget_color
        new_color = '#ff0000'
        expect { inbox.channel.update!(widget_color: new_color) }.to change(inbox_update_audits, :count).by(1)
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
        expect { inbox.update!(name: 'Updated Inbox') }.to change(inbox_update_audits, :count).by(1)
      end
    end

    context 'when channel is updated' do
      it 'has associated audit log created' do
        previous_webhook = inbox.channel.webhook_url
        new_webhook = 'https://example2.com'
        expect { inbox.channel.update!(webhook_url: new_webhook) }.to change(inbox_update_audits, :count).by(1)
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
        expect { inbox.update!(name: 'Updated Inbox') }.to change(inbox_update_audits, :count).by(1)
      end
    end

    context 'when channel is updated' do
      it 'has associated audit log created' do
        previous_phone_number = inbox.channel.phone_number
        new_phone_number = '1234567890'
        expect { inbox.channel.update!(phone_number: new_phone_number) }.to change(inbox_update_audits, :count).by(1)
        # Check for the specific phone_number update in the audit log
        expect(Audited::Audit.where(auditable_type: 'Inbox', action: 'update',
                                    audited_changes: { 'phone_number' => [previous_phone_number, new_phone_number] }).count).to eq(1)
      end
    end

    context 'when template sync runs' do
      it 'has no associated audit log created' do
        expect { channel.sync_templates }.not_to(change(inbox_update_audits, :count))
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
        expect do
          channel.update!(
            last_synced_at: Time.current,
            sync_state: channel.sync_state_payload.merge('last_incremental_sync_at' => Time.current.iso8601),
            connection_state: 'open',
            lifecycle_state: 'connected'
          )
        end.not_to(change(inbox_update_audits, :count))
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
