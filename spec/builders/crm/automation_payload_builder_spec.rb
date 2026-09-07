require 'rails_helper'

RSpec.describe Crm::AutomationPayloadBuilder do
  describe '.deal' do
    let(:account) { instance_double(Account, webhook_data: { id: 1, name: 'Acme' }) }
    let(:pipeline) { instance_double(Crm::Pipeline, id: 2, name: 'Sales') }
    let(:stage) { instance_double(Crm::Stage, id: 3, name: 'Qualified', outcome: 'open') }
    let(:owner) { instance_double(User, webhook_data: { id: 4, name: 'Owner' }) }
    let(:creator) { instance_double(User, webhook_data: { id: 5, name: 'Creator' }) }
    let(:team) { instance_double(Team, id: 6, name: 'Enterprise') }
    let(:company) { instance_double(Company, id: 7, name: 'Acme Ltd', domain: 'acme.test') }
    let(:conversation) { instance_double(Conversation, webhook_data: { id: 8, display_id: 80 }) }
    let(:communication_thread) do
      instance_double(CommunicationThread, id: 9, display_id: 90, contact_id: 10, status: 'open')
    end
    let(:contact) { instance_double(Contact, webhook_data: { id: 10, name: 'Buyer' }) }
    let(:deal) do
      instance_double(
        Crm::Deal,
        attributes: { 'id' => 11, 'title' => 'Renewal', 'internal_only' => true },
        primary_contact_id: 10,
        account: account,
        pipeline: pipeline,
        stage: stage,
        owner: owner,
        creator: creator,
        team: team,
        company: company,
        originating_conversation: conversation,
        originating_communication_thread: communication_thread,
        contacts: [contact]
      )
    end

    it 'serializes allowlisted attributes and related domain records' do
      expect(described_class.deal(deal)).to eq(
        account: { id: 1, name: 'Acme' },
        deal: { id: 11, title: 'Renewal', primary_contact_id: 10 },
        pipeline: { id: 2, name: 'Sales' },
        stage: { id: 3, name: 'Qualified', outcome: 'open' },
        owner: { id: 4, name: 'Owner' },
        creator: { id: 5, name: 'Creator' },
        team: { id: 6, name: 'Enterprise' },
        company: { id: 7, name: 'Acme Ltd', domain: 'acme.test' },
        conversation: { id: 8, display_id: 80 },
        communication_thread: { id: 9, display_id: 90, contact_id: 10, status: 'open' },
        contacts: [{ id: 10, name: 'Buyer' }]
      )
    end
  end

  describe '.task' do
    let(:account) { instance_double(Account, webhook_data: { id: 1, name: 'Acme' }) }
    let(:status) { instance_double(Crm::TaskStatus, id: 2, name: 'Open', category: 'open') }
    let(:assignee) { instance_double(User, webhook_data: { id: 3, name: 'Assignee' }) }
    let(:creator) { instance_double(User, webhook_data: { id: 4, name: 'Creator' }) }
    let(:team) { instance_double(Team, id: 5, name: 'Success') }
    let(:deal) { instance_double(Crm::Deal, id: 6, title: 'Renewal') }
    let(:conversation) { instance_double(Conversation, webhook_data: { id: 7, display_id: 70 }) }
    let(:task) do
      instance_double(
        Crm::Task,
        attributes: {
          'id' => 8,
          'title' => 'Call buyer',
          'context_kind' => 'sales',
          'internal_only' => true
        },
        account: account,
        status: status,
        assignee: assignee,
        creator: creator,
        team: team,
        deal: deal,
        originating_conversation: conversation
      )
    end

    it 'serializes allowlisted attributes and related domain records' do
      expect(described_class.task(task)).to eq(
        account: { id: 1, name: 'Acme' },
        task: { id: 8, title: 'Call buyer', context_kind: 'sales' },
        status: { id: 2, name: 'Open', category: 'open' },
        assignee: { id: 3, name: 'Assignee' },
        creator: { id: 4, name: 'Creator' },
        team: { id: 5, name: 'Success' },
        deal: { id: 6, title: 'Renewal' },
        conversation: { id: 7, display_id: 70 }
      )
    end
  end
end
