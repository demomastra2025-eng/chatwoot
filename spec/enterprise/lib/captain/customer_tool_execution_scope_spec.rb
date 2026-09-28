require 'rails_helper'

RSpec.describe Captain::CustomerToolExecutionScope do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:state) do
    {
      account_id: account.id,
      assistant_id: assistant.id,
      conversation: { id: conversation.id },
      contact: { id: contact.id }
    }
  end
  let(:run_context) { Captain::Runtime::RunContext.new({ state: state, current_agent: 'scenario_agent' }) }
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }

  it 'rejects a prompt-selected deal operation before any effect even when its policy and risk appear safe' do
    tool = Captain::Tools::CreateDealTool.new(assistant)
    allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    expect(tool).not_to receive(:perform)

    expect { tool.execute(tool_context, title: 'Leaked deal') }.to raise_error(ArgumentError, /customer AI/)
  end

  it 'rejects the legacy account adapter even without a ToolWrapper' do
    tool = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'create_task')
    allow(Captain::ToolPolicy).to receive(:execution_allowed?).and_return(true)
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    expect(tool).not_to receive(:invoke_delegate)

    expect { tool.execute(tool_context, title: 'Leaked task') }.to raise_error(ArgumentError, /customer AI/)
  end

  it 'rejects an explicitly bound scenario or prompt-selected tool at the wrapper before executing it' do
    run_context.context[:captain_v2_bound_tool_gate] = true
    run_context.context[:captain_v2_bound_tool_ids_by_agent] = { 'scenario_agent' => ['create_deal'] }
    tool = Captain::Tools::CreateDealTool.new(assistant)
    expect(tool).not_to receive(:execute)

    result = Captain::Runtime::ToolWrapper.new(tool, run_context).call(title: 'Prompt-selected deal')

    expect(result).to be_a(RubyLLM::Tool::Halt)
    expect(run_context.context[:captain_v2_terminal_tool_stop]).to include(
      result: include(audit: include(failure_reason: 'customer_tool_scope_denied'))
    )
  end

  it 'rejects a selected generic HTTP tool regardless of read-only metadata' do
    http_tool = create(:captain_custom_tool, account: account)
    tool = Captain::Tools::HttpTool.new(assistant, http_tool)
    expect(Captain::Tools::HttpRequestExecutor).not_to receive(:new)

    expect { tool.execute(tool_context) }.to raise_error(ArgumentError, /customer AI/)
  end

  it 'rejects MCP, script and handoff tools before provider or scenario side effects' do
    mcp_tool = Captain::Tools::McpTool.new(assistant, instance_double(Captain::McpServer), id: 'mcp__lookup', input_schema: {})
    script_tool = Captain::Tools::SkillScriptTool.new(assistant, id: 'skill_script_lookup', parameters_schema: {})
    scenario = Struct.new(:name).new('untrusted')
    scenario_tool = Captain::Runtime::HandoffTool.new(scenario)
    expect(Captain::Mcp::ExecutionService).not_to receive(:new)
    expect(Captain::SkillScriptRunner).not_to receive(:new)

    [mcp_tool, script_tool, scenario_tool].each do |tool|
      expect { tool.execute(tool_context) }.to raise_error(ArgumentError, /customer AI/)
    end
    empty_context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: {} }))
    expect { scenario_tool.execute(empty_context) }.to raise_error(ArgumentError, /customer AI/)
    expect(run_context.context[:pending_handoff]).to be_nil
  end

  it 'rejects missing identity, an account/assistant mismatch and a stale or foreign contact' do
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    another_account = create(:account)
    other_assistant = create(:captain_assistant, account: another_account)
    other_contact = create(:contact, account: account)
    allow(Captain::ToolExecutionAuditService).to receive(:record)

    [
      state.except(:conversation),
      state.except(:assistant_id),
      state.except(:contact),
      state.merge(account_id: another_account.id),
      state.merge(assistant_id: other_assistant.id),
      state.merge(contact: { id: other_contact.id }),
      state.merge(conversation: { id: create(:conversation, account: another_account).id })
    ].each do |invalid_state|
      context = Captain::Runtime::ToolContext.new(run_context: Captain::Runtime::RunContext.new({ state: invalid_state }))
      expect { tool.execute(context, name: 'Injected') }.to raise_error(ArgumentError, /customer AI/)
    end
    expect(contact.reload.name).not_to eq('Injected')
  end

  it 'rejects a stale run when the conversation is rebound after a wrapper preflight' do
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    other_contact = create(:contact, account: account)
    described_class.ensure_allowed!(tool: tool, state: state, params: { name: 'Stale mutation' }, assistant: assistant)
    conversation.update_columns(contact_id: other_contact.id) # rubocop:disable Rails/SkipsModelValidations -- simulate merge bulk rebind

    expect { tool.execute(tool_context, name: 'Stale mutation') }.to raise_error(described_class::Denied)
    expect(contact.reload.name).not_to eq('Stale mutation')
    expect(other_contact.reload.name).not_to eq('Stale mutation')
  end

  it 'does not mutate the Contact after a backdated incoming commits in another inbox' do
    create(:captain_inbox, captain_assistant: assistant, inbox: conversation.inbox)
    conversation.update!(status: :pending)
    trigger = create(:message, account: account, conversation: conversation,
                               inbox: conversation.inbox, message_type: :incoming)
    state[:captain_response_fence] = {
      control_generation: conversation.current_captain_control_generation,
      last_message_id: trigger.id
    }
    other_inbox = create(:inbox, account: account)
    sibling = create(:conversation, account: account, inbox: other_inbox, contact: contact)
    newer = create(:message, account: account, inbox: other_inbox, conversation: sibling,
                             message_type: :incoming, created_at: trigger.created_at - 1.minute)
    expect(newer.id).to be > trigger.id
    allow(Captain::ToolExecutionAuditService).to receive(:record)

    expect { Captain::Tools::UpdateContactTool.new(assistant).execute(tool_context, name: 'Late mutation') }
      .to raise_error(Captain::Conversation::ControlGenerationStaleError)
    expect(contact.reload.name).not_to eq('Late mutation')
  end

  it 'rejects a stale customer task after the conversation and its thread are rebound' do
    account.enable_features!('crm_tasks')
    thread = create(:communication_thread, account: account, contact: contact)
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation, primary: true)
    tool = Captain::Tools::CustomerTasksTool.new(assistant)
    other_contact = create(:contact, account: account)
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    described_class.ensure_allowed!(tool: tool, state: state, params: { action: 'list' }, assistant: assistant)
    conversation.update_columns(contact_id: other_contact.id) # rubocop:disable Rails/SkipsModelValidations -- simulate bulk rebind
    thread.update_columns(contact_id: other_contact.id) # rubocop:disable Rails/SkipsModelValidations -- simulate bulk rebind

    expect { tool.execute(tool_context, action: 'list') }.to raise_error(described_class::Denied)
  end

  it 'updates only the persisted current contact and forbids model-selected contact IDs' do
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    tool = Captain::Tools::UpdateContactTool.new(assistant)

    expect { tool.execute(tool_context, contact_id: create(:contact, account: account).id, name: 'Injected') }
      .to raise_error(ArgumentError, /customer AI/)

    result = JSON.parse(tool.execute(tool_context, name: 'Verified contact'))
    expect(result).to include('action' => 'update_contact', 'contact' => include('id' => contact.id))
    expect(contact.reload.name).to eq('Verified contact')
  end

  it 'refuses a customer AI identity/freshness spoof before it can bypass a MedElement provider read' do
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    patient_code = 'unverified-patient-code'
    attributes = { 'medelement_patient_code' => patient_code, 'medelement_last_synced_at' => Time.current.iso8601 }

    [attributes, attributes.to_json].each do |input|
      expect { tool.execute(tool_context, custom_attributes: input) }.to raise_error(described_class::Denied)
      expect(contact.reload.custom_attributes).not_to include('medelement_patient_code', 'medelement_last_synced_at')
    end

    client = instance_double(Integrations::Medelement::Client, get_patient: nil)
    resolver = Integrations::Medelement::ContactResolverService.new(account: account, client: client)
    expect(resolver.sync_patient!(patient_code)).to be_nil
    expect(client).to have_received(:get_patient).with(patient_code: patient_code)
  end

  it 'denies identifier and IIN aliases, mixed keys and invalid custom attribute shapes at both boundaries' do
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    forbidden = [
      { identifier: '950101300777' },
      { name: 'Untrusted', identifier: nil },
      { custom_attributes: { iin: '950101300777' } },
      { custom_attributes: { 'medelement_iin' => '950101300777' } },
      { custom_attributes: { safe_note: 'keep', medelement_patient_code: 'other' } },
      { custom_attributes: { 'secondary_phones' => ['+77770000000'] } },
      { custom_attributes: %w[safe medelement_patient_code] },
      { custom_attributes: { 42 => 'ambiguous key' } },
      { custom_attributes: '{"iin":"950101300777"}' },
      { custom_attributes: '["safe"]' },
      { custom_attributes: '{bad-json' }
    ]

    forbidden.each do |params|
      expect { described_class.ensure_allowed!(tool: tool, state: state, params: params, assistant: assistant) }
        .to raise_error(described_class::Denied)
      expect { tool.execute(tool_context, **params) }.to raise_error(described_class::Denied)
    end
    expect(contact.reload).to have_attributes(identifier: nil)
    expect(contact.custom_attributes).not_to include('iin', 'medelement_iin', 'medelement_patient_code', 'safe_note')
    resolver = Integrations::Medelement::ContactResolverService.new(account: account, client: nil)
    expect(resolver.send(:contacts_by_iin, '950101300777')).to be_empty
  end

  it 'allows ordinary contact fields and safe custom attributes from an object or JSON object' do
    tool = Captain::Tools::UpdateContactTool.new(assistant)
    allow(Captain::ToolExecutionAuditService).to receive(:record)

    safe_update = { name: 'Verified', email: 'verified@example.org', custom_attributes: { safe_note: 'visible' } }
    result = JSON.parse(tool.execute(tool_context, **safe_update))
    expect(result.dig('contact', 'id')).to eq(contact.id)
    expect(JSON.parse(tool.execute(tool_context, custom_attributes: '{"favorite_color":"green"}'))['action'])
      .to eq('update_contact')
    expect(contact.reload).to have_attributes(name: 'Verified', email: 'verified@example.org')
    expect(contact.custom_attributes).to include('safe_note' => 'visible', 'favorite_color' => 'green')
  end

  it 'allows get_contact only for the persisted current contact, not another account contact' do
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    tool = Captain::Tools::Agent::AccountToolAdapter.new(assistant, tool_id: 'get_contact')
    foreign_contact = create(:contact, account: account)

    expect { tool.execute(tool_context, contact_id: foreign_contact.id) }.to raise_error(ArgumentError, /customer AI/)
    expect(JSON.parse(tool.execute(tool_context, contact_id: contact.id)).dig('contact', 'id')).to eq(contact.id)
  end

  it 'lists customer tasks for this contact/thread and denies an off-contact task update before effect' do
    account.enable_features!('crm_tasks')
    thread = create(:communication_thread, account: account, contact: contact)
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation, primary: true)
    other_contact = create(:contact, account: account)
    other_conversation = create(:conversation, account: account, contact: other_contact)
    other_thread = create(:communication_thread, account: account, contact: other_contact)
    create(:communication_thread_conversation, communication_thread: other_thread, conversation: other_conversation, primary: true)
    foreign_task = create(
      :crm_task, account: account, originating_conversation: other_conversation,
                 customer_visible: true, customer_title: 'Other customer'
    )
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    tool = Captain::Tools::CustomerTasksTool.new(assistant)

    expect do
      tool.execute(tool_context, action: 'update', task_id: foreign_task.id,
                                 title: 'Injected', idempotency_key: 'off-contact')
    end.to raise_error(ArgumentError, /customer AI/)
    expect(JSON.parse(tool.execute(tool_context, action: 'list'))).to include('action' => 'list', 'tasks' => [])
    expect(foreign_task.reload.customer_title).to eq('Other customer')
  end

  it 'preserves create, update and cancel for customer-visible tasks of the current contact' do
    account.enable_features!('crm_tasks')
    thread = create(:communication_thread, account: account, contact: contact)
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation, primary: true)
    Crm::Bootstrap::AccountService.new(account: account).perform
    assignee = create(:user)
    create(:account_user, account: account, user: assignee)
    team = create(:team, account: account)
    create(:team_member, team: team, user: assignee)
    task_type = create(
      :crm_task_type, account: account, code: 'scope-task', customer_task_assignee: assignee,
                      customer_task_team: team
    )
    allow(Captain::ToolExecutionAuditService).to receive(:record)
    tool = Captain::Tools::CustomerTasksTool.new(assistant)

    create_args = {
      action: 'create', title: 'Current customer task',
      task_type: task_type.code, idempotency_key: 'scope-create-1'
    }
    created = JSON.parse(tool.execute(tool_context, **create_args))
    task = account.crm_tasks.find(created.dig('task', 'id'))
    task.update!(status: account.crm_task_statuses.find_by!(category: 'in_progress'))
    update_args = {
      action: 'update', task_id: task.id,
      request_reason: 'Please change it', idempotency_key: 'scope-update-1'
    }
    cancel_args = {
      action: 'cancel', task_id: task.id,
      request_reason: 'No longer needed', idempotency_key: 'scope-cancel-1'
    }
    changed = JSON.parse(tool.execute(tool_context, **update_args))
    cancelled = JSON.parse(tool.execute(tool_context, **cancel_args))

    expect(created['action']).to eq('created')
    expect(changed['action']).to eq('change_requested')
    expect(cancelled['action']).to eq('cancellation_requested')
    expect(task.reload).to have_attributes(originating_conversation_id: conversation.id,
                                           customer_change_request: 'Please change it',
                                           customer_cancellation_request: 'No longer needed')
  end

  it 'leaves the human administrator account tool scope unchanged' do
    admin = create(:user)
    create(:account_user, account: account, user: admin, role: :administrator)
    other_contact = create(:contact, account: account)
    service = Captain::Tools::Account::GetContactService.new(assistant, user: admin)

    expect(JSON.parse(service.execute(contact_id: other_contact.id)).dig('contact', 'id')).to eq(other_contact.id)

    update_tool = Captain::Tools::Account::UpdateContactService.new(assistant, user: admin, conversation: conversation)
    updated = JSON.parse(update_tool.execute(identifier: 'admin-managed-id', custom_attributes: { safe_note: 'admin' }))
    expect(updated.dig('contact', 'identifier')).to eq('admin-managed-id')
    expect(contact.reload.custom_attributes).to include('safe_note' => 'admin')
  end

  describe 'direct AI Voice dispatcher' do
    let(:call_session) do
      create(:telephony_call_session, account: account, contact: contact,
                                      conversation: conversation, inbox: conversation.inbox,
                                      external_call_ref: 'customer-scope-voice')
    end

    before do
      create(:captain_inbox, inbox: conversation.inbox, captain_assistant: assistant)
    end

    def dispatch_voice(tool_name, arguments = {})
      Telephony::AiVoice::ToolDispatchService.new(
        tool_name: tool_name,
        payload: { account_id: account.id, call_ref: call_session.external_call_ref, arguments: arguments }
      ).perform
    end

    it 'denies selected deal, appointment, arbitrary send_message and native contact creation/transfer before effect' do
      expect(Captain::ToolCatalog).not_to receive(:build_tool)

      %w[create_deal create_appointment send_message_to_conversation create_contact request_transfer end_call].each do |name|
        expect { dispatch_voice(name, title: 'Untrusted action') }.to raise_error(Telephony::Error) do |error|
          expect(error.code).to eq('CUSTOMER_AI_TOOL_SCOPE_DENIED')
        end
      end
      expect(contact.reload.name).not_to eq('Untrusted action')
    end

    it 'allows the current contact read but denies an off-contact ID' do
      assistant.update!(config: assistant.config.deep_merge('tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['get_contact'] } }))
      allow(Captain::ToolExecutionAuditService).to receive(:record)
      other_contact = create(:contact, account: account)

      denied = dispatch_voice('get_contact', contact_id: other_contact.id)
      expect(denied).to include(status: 'failed', result: a_string_including('customer AI'))

      allowed = dispatch_voice('get_contact', contact_id: contact.id)
      expect(allowed).to include(action: 'captain_tool', tool_name: 'get_contact')
      expect(JSON.parse(allowed[:result]).dig('contact', 'id')).to eq(contact.id)
    end

    it 'denies a voice call session without a trusted current contact' do
      call_session.update!(contact: nil)
      assistant.update!(config: assistant.config.deep_merge('tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['update_contact'] } }))
      expect(Captain::ToolCatalog).not_to receive(:build_tool)

      expect(dispatch_voice('update_contact', name: 'Untrusted'))
        .to include(status: 'failed', result: a_string_including('customer AI'))
      expect(contact.reload.name).not_to eq('Untrusted')
    end
  end
end
