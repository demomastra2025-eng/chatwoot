require 'rails_helper'

RSpec.describe Captain::Playground::ExecutionBoundary, 'workspace through the production tool wrapper' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }

  before do
    account.enable_features!('scheduling', 'crm_deals', 'crm_tasks')
    allow(Captain::ToolSafety).to receive(:check_arguments!)
    allow(Captain::ToolSafety).to receive(:check_result!)
    allow(assistant).to receive(:allowed_agent_tool_ids).and_return(%w[get_contact get_deal update_deal create_deal create_appointment get_appointment])
  end

  after { Current.reset }

  def wrapper(workspace, id)
    definition = Captain::ToolRegistry.definition_for(id)
    tool = if definition.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
             definition.agent_tool_class.new(assistant, tool_id: id)
           else
             definition.agent_tool_class.new(assistant)
           end
    state = workspace.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id)
    context = Captain::Runtime::RunContext.new({ state: state, playground_session: workspace })
    Captain::Runtime::ToolWrapper.new(tool, context)
  end

  def counts
    [Contact, Conversation, Message, Scheduling::Appointment, Crm::Deal, Crm::Task, Integrations::Medelement::ProviderCommand].map(&:count)
  end

  it 'creates and reads synthetic records with the production schemas and zero business database writes' do
    before_counts = counts
    expect(Scheduling::Appointments::UpsertService).not_to receive(:new)
    expect(Messages::MessageBuilder).not_to receive(:new)
    session.with_lock do |workspace|
      contact_id = workspace.payload.dig(:scenario, :contact, 'id')
      get_contact = wrapper(workspace, 'get_contact')
      expect(get_contact.params_schema.dig('properties', 'contact_id', 'anyOf')).to be_present
      expect(JSON.parse(get_contact.call(contact_id: contact_id)).dig('contact', 'name')).to eq('Айгуль Садыкова')
      deal = JSON.parse(wrapper(workspace, 'create_deal').call(title: 'Synthetic new deal'))
      expect(deal['deal_id']).to be_negative
      expect(JSON.parse(wrapper(workspace, 'get_deal').call(deal_id: deal['deal_id'])).dig('deal', 'title')).to eq('Synthetic new deal')
      scenario = workspace.payload[:scenario]
      start = (Time.iso8601(workspace.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601
      appointment = JSON.parse(wrapper(workspace, 'create_appointment').call(
                                 resource_id: scenario[:resources].first['id'], service_id: scenario[:services].first['id'], starts_at: start
                               ))
      expect(appointment).to include('success' => true, 'simulated' => true)
      expect(appointment['appointment_id']).to be_negative
      expect(appointment).to include('status' => 'created')
      expect(appointment['appointment']).to include('status' => 'scheduled', 'starts_at' => start)
      expect(JSON.parse(wrapper(workspace, 'get_appointment').call(appointment_id: appointment['appointment_id']))
        .dig('appointment', 'client_name')).to eq('Айгуль Садыкова')
    end
    expect(counts).to eq(before_counts)
  end

  it 'keeps negative synthetic references in JSON with real reads enabled, even when their positive local IDs exist' do
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: false)
      # Contacts use a 32-bit primary key in this schema. Keep the namespace
      # fixture in that range to exercise an actual abs-ID database collision.
      workspace.namespace.instance_variable_set(:@base, Captain::Playground::SyntheticNamespace::STRIDE)
      id = workspace.payload.dig(:scenario, :contact, 'id')
      real = create(:contact, account: account, id: -id, name: 'Real collision')
      expect(JSON.parse(wrapper(workspace, 'get_contact').call(contact_id: id)).dig('contact', 'name')).to eq('Айгуль Садыкова')
      expect(real.reload.name).to eq('Real collision')
      scenario = workspace.payload[:scenario]
      expect(Scheduling::Appointments::UpsertService).not_to receive(:new)
      result = wrapper(workspace, 'create_appointment').call(
        resource_id: scenario[:resources].first['id'], service_id: scenario[:services].first['id'],
        starts_at: (Time.iso8601(workspace.scenario.data['appointments'].first['starts_at']) + 1.hour).iso8601,
        patient: { first_name: 'Тимур', last_name: 'Садыков', iin: '150101500011' }
      )
      expect(JSON.parse(result)).to include('simulated' => true, 'success' => true)
    end
  end

  it 'rejects foreign-session and unknown local negative references before any real lookup' do
    foreign = Captain::Playground::SyntheticNamespace.new(SecureRandom.uuid).encode({ contact_id: 101 })[:contact_id]
    session.with_lock do |workspace|
      expect(wrapper(workspace, 'get_contact').call(contact_id: foreign)).to include('another Playground session')
      unknown = workspace.namespace.encode({ contact_id: 3030 })[:contact_id]
      expect(wrapper(workspace, 'get_contact').call(contact_id: unknown)).to include('Record is not available')
    end
  end

  it 'blocks real reads by default and delegates them with the current account actor only after read is on' do
    contact = create(:contact, account: account, name: 'Real allowed card')
    foreign = create(:contact)
    session.with_lock do |workspace|
      expect(wrapper(workspace, 'get_contact').call(contact_id: contact.id)).to include('Reading real data is disabled')
      workspace.set_permissions!(read: true, write: false)
      before_counts = counts
      expect(JSON.parse(wrapper(workspace, 'get_contact').call(contact_id: contact.id)).dig('contact', 'name')).to eq('Real allowed card')
      expect(wrapper(workspace, 'get_contact').call(contact_id: foreign.id)).to include('ERROR:')
      expect(counts).to eq(before_counts)
    end
  end

  it 'blocks real mutations until separately confirmed and revokes previews immediately outside the turn lock' do
    deal = create(:crm_deal, account: account)
    session.with_lock do |workspace|
      workspace.set_permissions!(read: true, write: false)
      expect(wrapper(workspace, 'update_deal').call(deal_id: deal.id, title: 'Not written')).to include('Changing real data is disabled')
      workspace.set_permissions!(read: true, write: true)
      expect(wrapper(workspace, 'update_deal').call(deal_id: deal.id, title: 'Preview only')).to include('playground_confirmation_required')
      expect(deal.reload.title).not_to eq('Preview only')
      approval = workspace.payload[:action_previews].first
      workspace.store.set_permissions(session_id: workspace.id, read: false, write: true)
      expect(workspace.payload).to include(real_data_read: false, real_data_write: false, action_previews: [])
      expect { Captain::Playground::ActionApproval.new(workspace).confirm(id: approval['id'], digest: approval['digest']) }
        .to raise_error(ArgumentError, /revoked/)
    end
  end

  it 'rejects forged and legacy Playground state without a server session' do
    context = Captain::Runtime::RunContext.new({ state: { source: 'playground', playground: { mode: 'live' } } })
    tool = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'get_contact')
    expect(tool).not_to receive(:execute)
    expect(Captain::Runtime::ToolWrapper.new(tool, context).call(contact_id: 1)).to include('Playground')
    expect { Captain::Playground::Session.new(account: account, user: user, assistant: assistant, mode: 'live') }
      .to raise_error(ArgumentError, /Legacy Live/)
  end
end
