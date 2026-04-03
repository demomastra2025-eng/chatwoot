require 'rails_helper'

RSpec.describe Integrations::Macrocrm::ManagerChangedProcessorService do
  subject(:perform) { described_class.new(hook: hook, payload: payload).perform }

  let(:account) { create(:account) }
  let(:whatsapp_channel) do
    create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false)
  end
  let(:inbox) { whatsapp_channel.inbox }
  let(:contact) { create(:contact, account: account, name: 'Ahan', phone_number: '+77001234567') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77001234567') }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox)
  end
  let(:payload) do
    {
      'action' => 'estate.managerChanged',
      'data' => {
        'event' => 'estate.managerChanged',
        'object' => {
          'estate_id' => 6841608,
          'client_phones' => '+7 (700) 123-45-67',
          'status' => 10,
          'previous_status' => 5,
          'updated_at' => '2026-03-28 18:53:43'
        }
      }
    }
  end
  let(:manager_mappings) { [] }
  let(:hook) do
    create(:integrations_hook,
           account: account,
           app_id: 'macrocrm',
           access_token: 'macro-secret',
           settings: {
             'app_id' => 'macro-app',
             'manager_mappings' => manager_mappings
           })
  end
  let(:client) { instance_double(Integrations::Macrocrm::Client) }

  before do
    conversation
    allow(Integrations::Macrocrm::Client).to receive(:new).with(hook: hook).and_return(client)
  end

  context 'when MacroCRM returns an assigned manager via estateBuy/list' do
    let!(:mapped_agent) { create(:user, account: account, role: :agent) }
    let(:manager_mappings) { [{ 'user_id' => mapped_agent.id, 'macro_manager_id' => 78731 }] }

    before do
      create(:inbox_member, inbox: inbox, user: mapped_agent)
      allow(client).to receive(:list_estate_buy).with(ids: [6841608], statuses: [10]).and_return(
        {
          'buys' => [
            {
              'id' => 6841608,
              'contact' => { 'phones' => ['+7 700 123 45 67'] },
              'manager' => { 'id' => 78731 }
            }
          ]
        }
      )
    end

    it 'assigns the mapped agent and stores the processed timestamp' do
      perform

      expect(conversation.reload.assignee).to eq(mapped_agent)
      expect(conversation.custom_attributes['macrocrm_manager_changed_at']).to eq(
        Time.zone.parse('2026-03-28 18:53:43').utc.iso8601
      )
    end
  end

  context 'when MacroCRM reports manager removal via estateBuy/list' do
    let!(:current_assignee) { create(:user, account: account, role: :agent) }

    before do
      create(:inbox_member, inbox: inbox, user: current_assignee)
      conversation.update!(assignee: current_assignee)
      allow(client).to receive(:list_estate_buy).with(ids: [6841608], statuses: [10]).and_return(
        {
          'buys' => [
            {
              'id' => 6841608,
              'contact' => { 'phones' => ['+7 700 123 45 67'] },
              'manager' => { 'id' => nil }
            }
          ]
        }
      )
    end

    it 'unassigns the conversation' do
      perform

      expect(conversation.reload.assignee_id).to be_nil
    end
  end

  context 'when estateBuy/list misses the estate and fallback resolves the manager' do
    let!(:mapped_agent) { create(:user, account: account, role: :agent) }
    let(:manager_mappings) { [{ 'user_id' => mapped_agent.id, 'macro_manager_id' => 78731 }] }

    before do
      create(:inbox_member, inbox: inbox, user: mapped_agent)
      allow(client).to receive(:list_estate_buy).with(ids: [6841608], statuses: [10]).and_return({ 'buys' => [] })
      allow(client).to receive(:find_contact).with(phone: '+77001234567').and_return(
        { 'contact' => { 'id' => 5044369 } }
      )
      allow(client).to receive(:find_estate_buy).with(contact_id: 5044369).and_return(
        { 'buys' => [{ 'id' => 6841608, 'manager_id' => 78731 }] }
      )
    end

    it 'falls back to contact/deal lookup and assigns the mapped agent' do
      perform

      expect(conversation.reload.assignee).to eq(mapped_agent)
    end
  end

  context 'when the manager is not mapped to a local assignable agent' do
    before do
      allow(client).to receive(:list_estate_buy).with(ids: [6841608], statuses: [10]).and_return(
        {
          'buys' => [
            {
              'id' => 6841608,
              'contact' => { 'phones' => ['+7 700 123 45 67'] },
              'manager' => { 'id' => 78731 }
            }
          ]
        }
      )
    end

    it 'keeps the conversation unchanged' do
      expect { perform }.not_to change { conversation.reload.assignee_id }
    end
  end

  context 'when the webhook is stale' do
    let!(:current_assignee) { create(:user, account: account, role: :agent) }

    before do
      create(:inbox_member, inbox: inbox, user: current_assignee)
      conversation.update!(
        assignee: current_assignee,
        custom_attributes: { 'macrocrm_manager_changed_at' => Time.zone.parse('2026-03-28 19:00:00').utc.iso8601 }
      )
      allow(client).to receive(:list_estate_buy).with(ids: [6841608], statuses: [10]).and_return(
        {
          'buys' => [
            {
              'id' => 6841608,
              'contact' => { 'phones' => ['+7 700 123 45 67'] },
              'manager' => { 'id' => nil }
            }
          ]
        }
      )
    end

    it 'ignores the older event' do
      expect { perform }.not_to change { conversation.reload.assignee_id }
      expect(conversation.reload.custom_attributes['macrocrm_manager_changed_at']).to eq(Time.zone.parse('2026-03-28 19:00:00').utc.iso8601)
    end
  end

  context 'when multiple conversations share the same phone but one has the linked estate id' do
    let!(:mapped_agent) { create(:user, account: account, role: :agent) }
    let(:manager_mappings) { [{ 'user_id' => mapped_agent.id, 'macro_manager_id' => 78731 }] }
    let!(:newer_conversation) do
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :open,
        last_activity_at: 5.minutes.from_now
      )
    end

    before do
      create(:inbox_member, inbox: inbox, user: mapped_agent)
      conversation.update!(
        custom_attributes: { 'macrocrm_estate_id' => '6841608' },
        last_activity_at: 10.minutes.ago
      )
      allow(client).to receive(:list_estate_buy).with(ids: [6841608], statuses: [10]).and_return(
        {
          'buys' => [
            {
              'id' => 6841608,
              'contact' => { 'phones' => ['+7 700 123 45 67'] },
              'manager' => { 'id' => 78731 }
            }
          ]
        }
      )
    end

    it 'prefers the conversation linked to the MacroCRM estate' do
      perform

      expect(conversation.reload.assignee).to eq(mapped_agent)
      expect(newer_conversation.reload.assignee_id).to be_nil
    end
  end

  context 'when phone fallback matches multiple unresolved conversations without an estate link' do
    let!(:mapped_agent) { create(:user, account: account, role: :agent) }
    let(:manager_mappings) { [{ 'user_id' => mapped_agent.id, 'macro_manager_id' => 78731 }] }
    let!(:newer_conversation) do
      create(
        :conversation,
        account: account,
        inbox: inbox,
        contact: contact,
        contact_inbox: contact_inbox,
        status: :open,
        last_activity_at: 5.minutes.from_now
      )
    end

    before do
      create(:inbox_member, inbox: inbox, user: mapped_agent)
      allow(client).to receive(:list_estate_buy).with(ids: [6841608], statuses: [10]).and_return(
        {
          'buys' => [
            {
              'id' => 6841608,
              'contact' => { 'phones' => ['+7 700 123 45 67'] },
              'manager' => { 'id' => 78731 }
            }
          ]
        }
      )
    end

    it 'skips assignment instead of choosing an arbitrary conversation' do
      perform

      expect(conversation.reload.assignee_id).to be_nil
      expect(newer_conversation.reload.assignee_id).to be_nil
      expect(conversation.reload.custom_attributes['macrocrm_manager_changed_at']).to be_nil
      expect(newer_conversation.reload.custom_attributes['macrocrm_manager_changed_at']).to be_nil
    end
  end

  context 'when event type is unrelated' do
    let(:payload) do
      { 'action' => 'estate.created', 'data' => { 'event' => 'estate.created', 'object' => { 'estate_id' => 6841608 } } }
    end

    it 'does nothing' do
      expect(client).not_to receive(:list_estate_buy)

      perform
    end
  end

  context 'when sync from MacroCRM is disabled in settings' do
    let(:hook) do
      create(:integrations_hook,
             account: account,
             app_id: 'macrocrm',
             access_token: 'macro-secret',
             settings: {
               'app_id' => 'macro-app',
               'sync_chat_manager_from_macro' => false,
               'manager_mappings' => manager_mappings
             })
    end

    it 'does nothing' do
      expect(client).not_to receive(:list_estate_buy)

      perform
    end
  end
end
