require 'rails_helper'

RSpec.describe Captain::Tools::UpdateDealTool do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:other_contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:run_context) do
    instance_double(Captain::Runtime::RunContext, context: { state: { conversation: { id: conversation.id } } })
  end
  let(:tool_context) { Captain::Runtime::ToolContext.new(run_context: run_context) }
  let(:neutral_failure) { Captain::Tools::Agent::PatientScope::FAILURE }

  before do
    account.enable_features!('crm_deals')
  end

  it 'updates only a deal linked to the current contact' do
    own = create(:crm_deal, account: account, title: 'Own deal')
    foreign = create(:crm_deal, account: account, title: 'Other deal')
    create(:crm_deal_contact, account: account, deal: own, contact: contact, primary: true)
    create(:crm_deal_contact, account: account, deal: foreign, contact: other_contact, primary: true)

    result = described_class.new(assistant).execute(tool_context, deal_id: own.id, title: 'Updated own deal')

    expect(JSON.parse(result).fetch('deal_id')).to eq(own.id)
    expect(own.reload.title).to eq('Updated own deal')
    expect(described_class.new(assistant).execute(tool_context, deal_id: foreign.id, title: 'Must not change')).to eq(neutral_failure)
    expect(described_class.new(assistant).execute(tool_context, deal_id: 2_147_483_647, title: 'Must not change')).to eq(neutral_failure)
    expect(foreign.reload.title).to eq('Other deal')
  end

  it 'takes the note target from the persisted conversation rather than a spoofed state contact' do
    spoofed_run_context = instance_double(
      Captain::Runtime::RunContext,
      context: { state: { conversation: { id: conversation.id }, contact: { id: other_contact.id } } }
    )
    spoofed_context = Captain::Runtime::ToolContext.new(run_context: spoofed_run_context)

    result = Captain::Tools::AddContactNoteTool.new(assistant).execute(spoofed_context, note: 'Own note')

    expect(result).to include('Note added successfully')
    expect(contact.notes.pluck(:content)).to include('Own note')
    expect(other_contact.notes.pluck(:content)).not_to include('Own note')
  end

  it 'creates a task for the current patient deal but denies a foreign deal' do
    account.enable_features!('crm_tasks')
    own = create(:crm_deal, account: account)
    foreign = create(:crm_deal, account: account)
    create(:crm_deal_contact, account: account, deal: own, contact: contact, primary: true)
    create(:crm_deal_contact, account: account, deal: foreign, contact: other_contact, primary: true)
    tool = Captain::Tools::CreateTaskTool.new(assistant)

    result = tool.execute(tool_context, title: 'Follow up', deal_id: own.id)

    expect(JSON.parse(result).fetch('task_id')).to be_present
    expect(tool.execute(tool_context, title: 'Must not create', deal_id: foreign.id)).to eq(neutral_failure)
    expect(account.crm_tasks.where(title: 'Must not create')).to be_empty
  end
end
