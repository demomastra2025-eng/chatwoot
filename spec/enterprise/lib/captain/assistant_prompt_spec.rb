# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::AssistantPrompt do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account, description: 'Use [@FAQ](tool://faq_lookup) for [$Name](field://contact.name).') }
  let(:context) { { instruction: assistant.description, global_system_instruction: 'Shared', runtime_tool_ids: %w[faq_lookup] } }
  let(:clock) { { now_utc: '2026-10-12T18:56:00Z', timezone: 'Asia/Almaty' } }
  let(:contact) { { 'id' => 7, 'name' => 'Aigerim', 'phone_number' => '+77000000000' } }

  def variables(state: {}, **overrides)
    described_class.new(assistant: assistant, context: context.merge(overrides), state: state, prompt_state: state[:prompt_context].to_h).variables
  end

  it 'returns the two resolved texts, the Now text and the Patient lines' do
    state = { runtime_clock: clock, prompt_context: { contact: contact } }

    expect(variables(state: state)).to eq(
      instruction: 'Use `faq_lookup` for Aigerim.',
      global_system_instruction: 'Shared',
      now_text: 'Monday, 12.10.2026, 23:56, Almaty (UTC+5).',
      patient_lines: ['Aigerim, +77000000000.']
    )
  end

  it 'returns empty Now and Patient parts for a run without state, as in a preview' do
    expect(variables).to include(now_text: '', patient_lines: [], instruction: 'Use `faq_lookup` for not specified.')
  end

  it 'writes every mention as its function name and shows no number when the context does not say which tools are bound' do
    unknown = context.except(:runtime_tool_ids)
    state = { prompt_context: { contact: contact, conversation: { 'display_id' => 15 } } }

    result = described_class.new(assistant: assistant, context: unknown, state: state, prompt_state: state[:prompt_context]).variables

    expect(result[:instruction]).to eq('Use `faq_lookup` for Aigerim.')
    expect(result[:patient_lines]).to eq(['Aigerim, +77000000000.'])
  end

  it 'writes the mention of a tool that is not in the bound list as its label' do
    expect(variables(runtime_tool_ids: [])[:instruction]).to eq('Use FAQ for not specified.')
  end

  it 'adds a number line only for a tool that takes that number' do
    state = { prompt_context: { contact: contact, conversation: { 'display_id' => 15, 'label_list' => ['vip'] } } }

    expect(variables(state: state, runtime_tool_ids: %w[get_contact assign_conversation])[:patient_lines]).to eq(
      ['Aigerim, +77000000000.', 'Patient number: 7.', 'Conversation labels: vip.', 'Conversation number: 15.']
    )
    expect(variables(state: state, runtime_tool_ids: %w[get_my_contact])[:patient_lines]).to eq(
      ['Aigerim, +77000000000.', 'Conversation labels: vip.']
    )
  end

  it 'reads a time field in the zone of the run clock' do
    account.enable_features!('crm_tasks')
    assistant.update!(description: 'Due [$Due](field://task.due_at).')
    due = { 'due_at' => Time.utc(2026, 10, 12, 20, 30) }
    moscow_clock = clock.merge(timezone: 'Europe/Moscow')

    almaty = variables(state: { runtime_clock: clock, prompt_context: { task: due } }, instruction: assistant.description)
    moscow = variables(state: { runtime_clock: moscow_clock, prompt_context: { task: due } }, instruction: assistant.description)

    expect(almaty[:instruction]).to eq('Due 13.10.2026 01:30.')
    expect(moscow[:instruction]).to eq('Due 12.10.2026 23:30.')
  end

  it 'never changes the run state it reads' do
    state = { runtime_clock: clock, prompt_context: { contact: contact } }
    before = Marshal.load(Marshal.dump(state))

    variables(state: state)

    expect(state).to eq(before)
  end
end
