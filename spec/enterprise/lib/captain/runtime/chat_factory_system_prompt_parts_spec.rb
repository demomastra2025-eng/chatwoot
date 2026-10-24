# frozen_string_literal: true

require 'rails_helper'

# The provider caches a request prefix byte for byte: the system prompt of an agent must start with everything that is the same for
# every request (platform rules, clinic instructions, the way of working with colleagues) and end with what changes per request
# (the clock, the patient language, the patient's data, the coordination data). Two requests of the same agent at different times,
# for different patients, must share the whole stable part. All data is synthetic.
RSpec.describe Captain::Runtime::ChatFactory, '.system_prompt_parts' do
  let(:account) { create(:account) }
  let(:entry) { create(:captain_assistant, account: account, description: 'ENTRY CLINIC INSTRUCTIONS') }
  let!(:specialist) do
    create(:captain_assistant, account: account, description: 'SPECIALIST CLINIC INSTRUCTIONS', routing_description: 'Детский приём')
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:runtime) { Captain::AgentRunContext.new(entry: entry, conversation: conversation) }
  let(:morning) { { now_utc: '2026-10-12T05:23:00Z', timezone: 'Asia/Almaty' } }
  let(:night) { { now_utc: '2026-10-14T20:41:00Z', timezone: 'Asia/Almaty' } }
  let(:first_request) do
    { clock: morning, contact: { id: 7, name: 'Ирина Павлова', phone_number: '+77010000006' }, language: 'ru', current_input: 'сколько стоит МРТ' }
  end
  let(:second_request) do
    { clock: night, contact: { id: 9, name: 'Алия Сейтова', phone_number: '+77010000009' }, language: 'kk', current_input: 'қабылдау қашан' }
  end

  def context_for(clock:, contact:, language:, current_input:)
    context = {
      state: { account_id: account.id, assistant_id: entry.id, runtime_clock: clock,
               conversation: { id: conversation.id, display_id: conversation.display_id }, contact: contact },
      conversation_history: [{ role: 'user', content: 'здравствуйте' }],
      captain_v2_current_input: current_input, patient_language: language
    }
    runtime.prepare(context)
    # Two agents on the channel, so the prompt has the colleagues block.
    context[:agent_graph] = [{ id: entry.id, key: "assistant_#{entry.id}", name: entry.name, description: '' },
                             { id: specialist.id, key: "assistant_#{specialist.id}", name: specialist.name,
                               description: 'Appointments for children' }]
    context
  end

  def parts_for(**request)
    parts_of(context_for(**request))
  end

  def parts_of(context, **)
    described_class.system_prompt_parts(entry.agent, Captain::Runtime::RunContext.new(context), **)
  end

  def part_context(request, message, fragment)
    context_for(**request).merge(part_run: true, part_customer_message: message, part_info: { fragment: fragment })
  end

  def common_prefix_length(first, second)
    first.chars.zip(second.chars).take_while { |one, other| one == other }.size
  end

  it 'gives two requests at different times for different patients the identical stable part' do
    first = parts_for(**first_request)
    second = parts_for(**second_request)

    expect(first.stable).to eq(second.stable)
    expect(first.stable).to include('# Platform rules', "# Clinic instructions\nENTRY CLINIC INSTRUCTIONS", '# Colleagues on this channel',
                                    'How to work together')
    expect(first.volatile).not_to eq(second.volatile)
  end

  it 'keeps the clock, the patient language and the patient data out of the stable part and puts them in the volatile part' do
    first = parts_for(**first_request)

    expect(first.stable).not_to include('# Now', '# Patient', 'Patient language:', 'Ирина Павлова', 'October 2026', '+77010000006')
    expect(first.volatile).to include("# Now\nMonday, 12 October 2026 (2026-10-12), 10:23, Almaty (UTC+5)",
                                      'Patient language: Russian. Reply in Russian.', "# Patient\nИрина Павлова, +77010000006.")
  end

  it 'makes the whole prompts of the two requests share their prefix up to the volatile block, and differ only after it' do
    first = parts_for(**first_request)
    second = parts_for(**second_request)

    expect(first.to_s).not_to eq(second.to_s)
    expect(first.to_s).to start_with(first.stable)
    expect(common_prefix_length(first.to_s, second.to_s)).to be >= first.stable.length
    expect(first.to_s.index('# Now')).to be >= first.stable.length
    expect(first.to_s.split('# Now', 2).first).to eq(second.to_s.split('# Now', 2).first)
  end

  it 'writes the same prompt for every step of one run' do
    context = context_for(**first_request)
    first_step = parts_of(context).to_s
    second_step = parts_of(context).to_s

    expect(second_step).to eq(first_step)
  end

  it 'puts the data blocks of the coordination after the clock and the patient, and keeps them out of the stable part' do
    plain = parts_for(**first_request)
    context = context_for(**first_request)
    context[:parts] = [{ 'id' => 'open-part', 'version' => 1, 'state' => 'waiting_customer', 'executor_agent_id' => specialist.id,
                         'fragment' => 'запись ребенка', 'missing_fields' => ['Сколько лет ребенку?'] }]
    with_open_part = parts_of(context)

    expect(with_open_part.stable).to eq(plain.stable)
    expect(with_open_part.volatile).to include('# Open parts (data)', 'Сколько лет ребенку?')
    expect(with_open_part.to_s.index('# Open parts (data)')).to be > with_open_part.to_s.index('# Patient')
    expect(plain.volatile).not_to include('Open parts')
  end

  it 'gives the owner of a council part the same stable part for every request, and the patient message and language last' do
    first = parts_of(part_context(first_request, 'сколько стоит МРТ', 'МРТ'))
    second = parts_of(part_context(second_request, 'қабылдау қашан', 'қабылдау'))

    expect(first.stable).to eq(second.stable)
    expect(first.stable).to include("You handle ONE part of the patient's message", "# Clinic instructions\nENTRY CLINIC INSTRUCTIONS")
    expect(first.volatile).to include("Patient's latest message (data): \"сколько стоит МРТ\"", 'Patient language: Russian. Reply in Russian.')
    expect(first.to_s.index("Patient's latest message")).to be > first.to_s.index('# Patient')
    expect(first.stable).not_to include("Patient's latest message", 'Patient language:')
  end

  it 'adds the note of a finalization-only run at the very end' do
    parts = parts_of(context_for(**first_request), finalization_only: true)

    expect(parts.to_s).to end_with(described_class::FINALIZATION_ONLY_INSTRUCTIONS)
    expect(parts.stable).to eq(parts_for(**first_request).stable)
  end

  it 'is the same text as the single prompt of the agent: the stable part, a blank line, the volatile part' do
    context = Captain::Runtime::RunContext.new(context_for(**first_request))
    parts = entry.agent_instruction_parts(context)

    expect(entry.agent_instructions(context)).to eq("#{parts.stable}\n\n#{parts.volatile}")
    expect(parts.stable).to start_with('# Platform rules')
    expect(parts.volatile).to start_with('# Now')
  end
end
