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
      now_text: 'Monday, 12 October 2026 (2026-10-12), 23:56, Almaty (UTC+5). Tomorrow: Tuesday, 13 October 2026 (2026-10-13).',
      patient_lines: ['Aigerim, +77000000000.']
    )
  end

  it 'adds the night line after the clock line between 00:00 and 05:00 and before the reply window line' do
    night = { now_utc: '2026-10-12T20:15:00Z', timezone: 'Asia/Almaty' }
    window = { channel: 'official_whatsapp', closes_at: '2026-10-13T10:00:00Z', open_now: true }

    expect(variables(state: { runtime_clock: night, reply_window: window })[:now_text].split("\n")).to eq(
      [
        'Tuesday, 13 October 2026 (2026-10-13), 01:15, Almaty (UTC+5). Tomorrow: Wednesday, 14 October 2026 (2026-10-14).',
        'It is after midnight: a patient\'s "tomorrow" may mean today, Tuesday, 13 October 2026 (2026-10-13). ' \
        'For "today" or "tomorrow" offer free slots with the full date and book after the patient picks one.',
        'WhatsApp reply window is open until 13.10.2026 15:00; after that only approved templates can be sent.'
      ]
    )
  end

  it 'adds the decided language in the Now block' do
    result = variables(state: { runtime_clock: clock }, patient_language: 'kk')

    expect(result[:now_text].lines.last.strip).to eq('Patient language: Kazakh. Reply in Kazakh.')
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

  it 'writes the mention of a tool that a council part does not get as its label, and the others as function names' do
    assistant.update!(description: 'Ask [@FAQ](tool://faq_lookup) or hand over with [@Handoff](tool://handoff).')
    tools = %w[faq_lookup handoff resolve_conversation cancel_response]
    own_run = described_class.new(assistant: assistant, context: context.merge(instruction: assistant.description, runtime_tool_ids: tools),
                                  state: {}, prompt_state: {})
    part_run = described_class.new(assistant: assistant, context: context.merge(instruction: assistant.description, runtime_tool_ids: tools),
                                   state: {}, prompt_state: {}, part: true)

    expect(own_run.variables[:instruction]).to eq('Ask `faq_lookup` or hand over with `handoff`.')
    expect(part_run.variables[:instruction]).to eq('Ask `faq_lookup` or hand over with Handoff.')
  end

  it 'adds a number line only for a tool that takes that number' do
    state = { prompt_context: { contact: contact, conversation: { 'display_id' => 15, 'label_list' => ['vip'] } } }

    expect(variables(state: state, runtime_tool_ids: %w[get_contact assign_conversation])[:patient_lines]).to eq(
      ['Aigerim, +77000000000.', 'Patient ID: 7.', 'Conversation labels: vip.', 'Conversation ID: 15.']
    )
    expect(variables(state: state, runtime_tool_ids: %w[get_my_contact])[:patient_lines]).to eq(
      ['Aigerim, +77000000000.', 'Conversation labels: vip.']
    )
  end

  it 'adds the conversation ID for send_message_to_conversation, which has no default conversation in the agent runtime' do
    state = { prompt_context: { contact: contact, conversation: { 'display_id' => 15 } } }

    expect(variables(state: state, runtime_tool_ids: %w[send_message_to_conversation])[:patient_lines]).to eq(
      ['Aigerim, +77000000000.', 'Conversation ID: 15.']
    )
    expect(variables(state: state, runtime_tool_ids: %w[send_notification remove_label_from_conversation])[:patient_lines]).to eq(
      ['Aigerim, +77000000000.']
    )
  end

  describe 'the summaries that the clinic instruction does not place' do
    let(:appointment_summary) do
      {
        kind: 'appointments',
        groups: [{ key: 'upcoming', total: 1,
                   items: [{ id: 5, status: 'scheduled', date: '15.10.2026', time: '10:30', doctor: 'Иванов', service: 'Приём' }] }]
      }
    end
    let(:deal_summary) do
      {
        kind: 'deals',
        groups: [{ key: 'active', total: 1,
                   items: [{ id: 8, title: 'Имплантация', stage: 'Консультация', amount: '150000', currency: 'KZT' }] }]
      }
    end
    let(:state) do
      { prompt_context: { contact: contact, context_summaries: { appointment: appointment_summary, deal: deal_summary } } }
    end
    let(:appointment_line) do
      'Appointments: upcoming: Thu 15.10.2026 10:30, «Приём», Иванов; no past or cancelled appointments.'
    end
    let(:deal_line) { 'Deals: open: «Имплантация», stage «Консультация», 150000 KZT; no closed deals.' }

    it 'adds one line per selected summary to the Patient lines when the instruction has no $ reference to it' do
      expect(variables(state: state)[:patient_lines]).to eq(['Aigerim, +77000000000.', appointment_line, deal_line])
    end

    it 'adds a Patient block even when the patient has neither a name nor a phone' do
      expect(variables(state: { prompt_context: { context_summaries: { appointment: appointment_summary } } })[:patient_lines])
        .to eq([appointment_line])
    end

    it 'writes the number of a record in the line only when a bound tool takes it' do
      lines = variables(state: state, runtime_tool_ids: %w[cancel_appointment get_deal])[:patient_lines]

      expect(lines).to include(
        appointment_line.sub('upcoming: Thu', 'upcoming: #5 Thu'),
        deal_line.sub('open: «', 'open: #8 «')
      )
    end

    it 'leaves out the summary that the instruction writes itself, so the model sees it once' do
      account.enable_features!('scheduling')
      assistant.update!(description: 'Records: [$Summary](field://appointment.summary).')

      placed = state.deep_merge(prompt_context: { appointment: { 'summary' => appointment_summary } })

      result = variables(state: placed, instruction: assistant.description)

      expect(result[:instruction]).to eq(
        'Records: upcoming: Thu 15.10.2026 10:30, «Приём», Иванов; no past or cancelled appointments.'
      )
      expect(result[:patient_lines]).to eq(['Aigerim, +77000000000.', deal_line])
    end

    it 'adds nothing for a run with no summary, an empty summary or an unknown shape' do
      expect(variables(state: { prompt_context: { contact: contact } })[:patient_lines]).to eq(['Aigerim, +77000000000.'])
      empty = { prompt_context: { contact: contact, context_summaries: { appointment: nil, deal: { 'unknown' => 'shape' } } } }
      expect(variables(state: empty)[:patient_lines]).to eq(['Aigerim, +77000000000.'])
    end

    it 'reads a state whose keys are strings' do
      string_keys = { prompt_context: { contact: contact, context_summaries: { 'appointment' => appointment_summary.deep_stringify_keys } } }

      expect(variables(state: string_keys)[:patient_lines]).to eq(['Aigerim, +77000000000.', appointment_line])
    end

    it 'never changes the summary it reads' do
      before = Marshal.load(Marshal.dump(state))

      variables(state: state)

      expect(state).to eq(before)
    end
  end

  describe 'what the agents already did in this conversation' do
    let(:state) { { prompt_context: { contact: contact } } }
    let(:done) do
      { request: 'request:41',
        entries: [{ 'label' => 'Rescheduled', 'text' => 'Терапевт Абдрахманова Сауле, now Thu 15.10.2026 11:00', 'request' => 'request:41' },
                  { 'label' => 'Booked', 'text' => 'Терапевт Абдрахманова Сауле, Tue 13.10.2026 15:00', 'request' => 'request:30' }] }
    end

    def patient_lines(done:, state: self.state)
      described_class.new(assistant: assistant, context: context, state: state, prompt_state: state[:prompt_context].to_h, done: done)
                     .variables[:patient_lines]
    end

    it 'closes the Patient lines with the list, newest first, each action marked as done in reply to this message or earlier' do
      expect(patient_lines(done: done)).to eq(
        ['Aigerim, +77000000000.',
         'Done in this conversation:',
         '- Rescheduled: Терапевт Абдрахманова Сауле, now Thu 15.10.2026 11:00 (in reply to this message)',
         '- Booked: Терапевт Абдрахманова Сауле, Tue 13.10.2026 15:00 (earlier)']
      )
    end

    it 'comes after the summaries of the appointments and the deals' do
      summary = { kind: 'deals', groups: [{ key: 'active', total: 1, items: [{ id: 8, title: 'Имплантация', stage: 'Консультация' }] }] }
      with_summary = { prompt_context: { contact: contact, context_summaries: { deal: summary } } }

      lines = patient_lines(done: done, state: with_summary)

      expect(lines.index { |line| line.start_with?('Deals:') }).to be < lines.index('Done in this conversation:')
    end

    it 'is a Patient block of its own when the patient has no name and no phone' do
      expect(patient_lines(done: done, state: {}).first).to eq('Done in this conversation:')
    end

    it 'adds nothing when nothing was done or the run knows no list' do
      expect(patient_lines(done: nil)).to eq(['Aigerim, +77000000000.'])
      expect(patient_lines(done: { entries: [], request: 'request:41' })).to eq(['Aigerim, +77000000000.'])
    end

    it 'does not change the list it reads' do
      before = Marshal.load(Marshal.dump(done))

      patient_lines(done: done)

      expect(done).to eq(before)
    end
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
