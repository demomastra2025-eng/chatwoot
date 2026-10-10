require 'rails_helper'

RSpec.describe Captain::Playground::ContactCompanyTools, 'through the production tool wrapper' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :administrator) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:session) { Captain::Playground::Session.new(account: account, user: user, assistant: assistant) }
  let(:tool_ids) { described_class::CONTACT_COMPANY_ARGUMENTS.keys }

  before do
    account.enable_features!('companies', 'scheduling', 'crm_deals', 'crm_tasks')
    allow(assistant).to receive(:allowed_agent_tool_ids).and_return(tool_ids)
  end

  after { Current.reset }

  def wrapper(workspace, id)
    definition = Captain::ToolRegistry.definition_for(id)
    tool = if definition.agent_tool_class == Captain::Tools::Agent::AccountToolAdapter
             definition.agent_tool_class.new(assistant, tool_id: id)
           else
             definition.agent_tool_class.new(assistant)
           end
    state = workspace.state.merge(source: 'playground', account_id: account.id, assistant_id: assistant.id,
                                  captain_v2_bound_tool_gate: true, captain_v2_bound_tool_ids: tool_ids)
    context = Captain::Runtime::RunContext.new({ state: state, playground_session: workspace })
    Captain::Runtime::ToolWrapper.new(tool, context)
  end

  def invoke(workspace, id, **arguments)
    value = wrapper(workspace, id).call(arguments)
    return value.deep_stringify_keys if value.is_a?(Hash)

    payload = JSON.parse(value.delete_prefix('ERROR:').strip)
    Captain::ToolResult.error?(value) ? payload.merge('success' => false) : payload
  rescue JSON::ParserError
    { 'success' => false, 'error' => value.to_s }
  end

  def synthetic_id(workspace, key, id)
    workspace.namespace.encode({ key => id }).fetch(key)
  end

  def counts
    [Contact, Company, Conversation, Message, Crm::Deal, Scheduling::Appointment, Integrations::Medelement::ProviderCommand].map(&:count)
  end

  it 'uses required production ID schemas, returns native contact fields, and denies a different patient' do
    session.with_lock do |workspace|
      caller = workspace.scenario.contact
      id = synthetic_id(workspace, 'contact_id', caller['id'])
      schema = wrapper(workspace, 'get_contact').params_schema
      expect(schema['required']).to include('contact_id')
      expect(schema.dig('properties', 'contact_id')).to be_present
      result = invoke(workspace, 'get_contact', contact_id: id)
      expect(result['contact']).to include('id' => id, 'name' => caller['name'], 'company_name' => nil, 'blocked' => false)
      expect(result['contact'].keys).to include('created_at', 'updated_at', 'last_activity_at', 'custom_attributes', 'additional_attributes')
      patient = workspace.scenario.data['contacts'].find { |record| record['id'] != caller['id'] }
      denied = invoke(workspace, 'get_contact', contact_id: synthetic_id(workspace, 'contact_id', patient['id']))
      expect(denied['success']).to be(false)
      expect(denied['error']).to include('Record is not available')
    end
  end

  it 'searches only the caller with exact email/phone filters and the production ILIKE wildcard semantics' do
    session.with_lock do |workspace|
      caller = workspace.scenario.contact
      caller['name'] = 'Caller A_B%Tester'
      expect(invoke(workspace, 'search_contacts', email: caller['email'], phone_number: caller['phone_number'], name: 'caller a_b%')['total_count']).to eq(1)
      expect(invoke(workspace, 'search_contacts', email: caller['email'].upcase)['total_count']).to eq(0)
      expect(invoke(workspace, 'search_contacts', phone_number: '77010000001')['total_count']).to eq(0)
      expect(invoke(workspace, 'search_contacts', name: 'A\\_B\\%')['total_count']).to eq(1)
      expect(invoke(workspace, 'search_contacts', name: 'A\\_C')['total_count']).to eq(0)
      expect(invoke(workspace, 'search_contacts', name: 'Тимур')['contacts']).to eq([])
      expect(wrapper(workspace, 'search_contacts').params_schema.fetch('properties')).not_to have_key('offset')
      expect(invoke(workspace, 'search_contacts', offset: 1)['success']).to be(false)
    end
  end

  it 'creates a company with native normalization/defaults and links only the caller, with zero business writes' do
    session.with_lock do |workspace|
      before_counts = counts
      expect(Captain::Tools::Operations::ContactOperations).not_to receive(:new)
      expect(Company).not_to receive(:create!)
      expect(Contact).not_to receive(:create!)
      created = invoke(workspace, 'create_company', name: '  Example Clinic  ', domain: ' CLINIC.EXAMPLE.TEST ', description: ' Synthetic clinic ')
      expect(created).to include('action' => 'create_company', 'name' => 'Example Clinic', 'domain' => 'clinic.example.test', 'simulated' => true)
      expect(created['company_id']).to be_negative
      expect(created['company']).to include('account_id' => account.id, 'contacts_count' => 1, 'custom_attributes' => {},
                                           'additional_attributes' => {}, 'description' => 'Synthetic clinic')
      caller_id = synthetic_id(workspace, 'contact_id', workspace.scenario.contact['id'])
      expect(invoke(workspace, 'get_contact', contact_id: caller_id)['contact']).to include('company_id' => created['company_id'], 'company_name' => 'Example Clinic')
      expect(workspace.scenario.data['contacts'].reject { |record| record == workspace.scenario.contact }.map { |record| record['company_id'] }).to all(be_nil)
      expect(invoke(workspace, 'get_company', company_id: created['company_id'])['company']).to eq(created['company'])
      expect(invoke(workspace, 'create_company', name: 'Second company')['success']).to be(false)
      expect(workspace.scenario.data['companies'].size).to eq(1)
      expect(counts).to eq(before_counts)
    end
  end

  it 'filters companies before count/limit and orders equal names by ID without invented offset paging' do
    session.with_lock do |workspace|
      workspace.scenario.data['companies'] = [
        { 'id' => 1204, 'name' => 'Gamma', 'domain' => 'gamma.test' },
        { 'id' => 1203, 'name' => 'Beta', 'domain' => 'two.example.test' },
        { 'id' => 1202, 'name' => 'Beta', 'domain' => 'one.example.test' },
        { 'id' => 1201, 'name' => 'Alpha', 'domain' => 'alpha.test' }
      ]
      result = invoke(workspace, 'search_companies', name: '%ETA', domain: 'EXAMPLE_', limit: 1)
      expect(result).to include('total_count' => 2, 'filters' => { 'name' => '%ETA', 'domain' => 'EXAMPLE_' })
      expect(result['companies'].map { |record| record['id'] }).to eq([synthetic_id(workspace, 'company_id', 1202)])
      expect(invoke(workspace, 'search_companies', limit: 0)['companies'].map { |record| record['name'] }).to eq(%w[Alpha Beta Beta Gamma])
      expect(invoke(workspace, 'search_companies', limit: 2.8)['companies'].size).to eq(2)
      expect(wrapper(workspace, 'search_companies').params_schema.fetch('properties')).not_to have_key('offset')
      expect(invoke(workspace, 'search_companies', offset: 1)['success']).to be(false)
    end
  end

  it 'updates the linked company, preserves defaults, and rejects invalid or duplicate domains atomically' do
    session.with_lock do |workspace|
      created = invoke(workspace, 'create_company', name: 'Original', domain: 'original.test')
      workspace.scenario.data['companies'] << { 'id' => 1202, 'name' => 'Other', 'domain' => 'other.test' }
      changed = invoke(workspace, 'update_company', name: ' Changed ', description: '  ')
      expect(changed).to include('company_id' => created['company_id'], 'name' => 'Changed')
      expect(changed['company']).to include('description' => nil, 'custom_attributes' => {}, 'additional_attributes' => {})
      expect(invoke(workspace, 'update_company', domain: 'https://wrong.test/path')['success']).to be(false)
      expect(invoke(workspace, 'update_company', domain: ' OTHER.TEST ')['success']).to be(false)
      expect(invoke(workspace, 'get_company', company_id: created['company_id'])['company']).to include('name' => 'Changed', 'domain' => 'original.test')
      expect(workspace.scenario.data['companies'].last['name']).to eq('Other')
      expect(wrapper(workspace, 'update_company').params_schema.fetch('properties')).not_to have_key('company_id')
      expect(invoke(workspace, 'update_company', company_id: synthetic_id(workspace, 'company_id', 1202), name: 'Hijack')['success']).to be(false)
    end
  end

  it 'does not allocate IDs or link the caller after invalid creation and rejects foreign-session handles' do
    session.with_lock do |workspace|
      before_data = workspace.scenario.data.deep_dup
      expect(invoke(workspace, 'create_company', name: 'Invalid', domain: 'not a domain')['success']).to be(false)
      expect(invoke(workspace, 'create_company', name: 'x' * (Limits::COMPANY_NAME_LENGTH_LIMIT + 1))['success']).to be(false)
      expect(workspace.scenario.data).to eq(before_data)
      foreign = Captain::Playground::SyntheticNamespace.new('other-session').encode({ company_id: 1001 })[:company_id]
      expect(invoke(workspace, 'get_company', company_id: foreign)['success']).to be(false)
      expect(workspace.scenario.data).to eq(before_data)
    end
  end

  it 'uses native contact normalization and preserves protected patient/share attributes' do
    session.with_lock do |workspace|
      caller = workspace.scenario.contact
      caller['additional_attributes']['country_code'] = 'KZ'
      caller['custom_attributes'].merge!('medelement_patient_code' => 'synthetic-card', 'secondary_phones' => ['+77010000001'])
      before_counts = counts
      result = invoke(workspace, 'update_contact', name: '  Updated caller ', email: ' EDITED@EXAMPLE.TEST ',
                      phone_number: '8 (701) 234-56-78', custom_attributes: { medelement_patient_code: 'forged', secondary_phones: [], note: 'Allowed' })
      expect(result['contact']).to include('name' => 'Updated caller', 'email' => 'edited@example.test', 'phone_number' => '+77012345678')
      expect(result.dig('contact', 'custom_attributes')).to include('medelement_patient_code' => 'synthetic-card',
                                                                 'secondary_phones' => ['+77010000001'], 'note' => 'Allowed')
      expect(counts).to eq(before_counts)
    end
  end

  it 'rejects invalid email/duplicate identity without changing either contact and never reads native companies' do
    session.with_lock do |workspace|
      patient = workspace.scenario.data['contacts'].find { |record| record != workspace.scenario.contact }
      patient['email'] = 'other@example.test'
      before_data = workspace.scenario.data.deep_dup
      expect(invoke(workspace, 'update_contact', email: 'invalid-email')['success']).to be(false)
      expect(invoke(workspace, 'update_contact', email: 'OTHER@EXAMPLE.TEST')['success']).to be(false)
      expect(invoke(workspace, 'update_contact', phone_number: patient['phone_number'])['success']).to be(false)
      expect(invoke(workspace, 'update_contact', identifier: patient['identifier'])['success']).to be(false)
      expect(workspace.scenario.data).to eq(before_data)
      workspace.scenario.contact['company_id'] = 1701
      expect(Company).not_to receive(:find_by)
      expect(Company).not_to receive(:where)
      id = synthetic_id(workspace, 'contact_id', workspace.scenario.contact['id'])
      expect(invoke(workspace, 'get_contact', contact_id: id).dig('contact', 'company_name')).to be_nil
    end
  end

  it 'keeps another caller reserved family number out of the current contact while accepting unrelated edits' do
    session.with_lock do |workspace|
      caller = workspace.scenario.contact
      original_phone = caller['phone_number']
      patient = workspace.scenario.data['contacts'].find { |record| record != caller }
      reserved_phone = '+77015550000'
      workspace.scenario.data['contacts'] << { 'id' => 1301, 'name' => 'Hidden-number caller', 'phone_number' => nil,
                                             'custom_attributes' => {}, 'additional_attributes' => {} }
      patient['custom_attributes'].merge!(Contacts::SharedPhone::SHARED_PHONE_KEY => reserved_phone,
                                          Contacts::SharedPhone::SECONDARY_PHONES_KEY => [reserved_phone],
                                          Contacts::SharedPhone::SHARED_OWNER_KEY => 1301,
                                          Contacts::SharedPhone::SHARED_VIA_KEY => Contacts::SharedPhone::VIA_BOOKING_CHAT)
      expect(Contacts::SharedPhone).not_to receive(:reservation_owner_ids)
      expect(Contacts::SharedPhone).not_to receive(:recorded_shares)
      result = invoke(workspace, 'update_contact', name: 'Edited independently', phone_number: reserved_phone)
      expect(result['contact']).to include('name' => 'Edited independently', 'phone_number' => original_phone)
      expect(workspace.scenario.data['contacts'].last['phone_number']).to be_nil
      expect(workspace.scenario.data['conversation']['contact_id']).to eq(caller['id'])
    end
  end
end
