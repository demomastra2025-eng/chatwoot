require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }

  before { account.enable_features!('scheduling') }

  it 'recommends the appointment summary only on new profiles with scheduling tools' do
    config = {
      'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['list_my_appointments'] } },
      'context_access' => {}
    }
    assistant = create(:captain_assistant, account: account, config: config)
    expect(assistant.config.dig('context_access', 'appointment')).to eq(
      'enabled' => true,
      'field_ids' => %w[appointment.summary]
    )

    existing = create(:captain_assistant, account: account, config: { 'context_access' => {} })
    existing_config = {
      'context_access' => {},
      'tool_access' => { 'agent' => { 'tool_ids' => ['list_my_appointments'] } }
    }
    existing.update!(config: existing_config)
    expect(existing.reload.config['context_access']).to eq({})
  end

  it 'renders selected blocks and single fields from the same nearest appointment' do
    travel_to(Time.zone.parse('2026-10-09 12:00:00 UTC')) do
      create(:scheduling_appointment, account: account, contact: contact, conversation: conversation,
                                      starts_at: 1.day.ago, ends_at: 1.day.ago + 30.minutes, status: 'completed')
      nearest = create(:scheduling_appointment, account: account, contact: contact,
                                                starts_at: 10.minutes.ago, ends_at: 20.minutes.from_now,
                                                status: 'confirmed')
      create(:scheduling_appointment, account: account, contact: contact,
                                      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 30.minutes)
      config = {
        'context_access' => {
          'appointment' => { 'enabled' => true, 'field_ids' => %w[appointment.nearest appointment.status] }
        }
      }
      assistant = create(:captain_assistant, account: account, config: config)
      state = Captain::ContextFields.runtime_state_for(account: account, conversation: conversation, assistant: assistant)
      prompt = assistant.prompt_context_state(state)

      expect(assistant.selected_context_field_ids).to include('appointment.nearest', 'appointment.status')
      expect(state.dig(:appointment, :id)).to eq(nearest.id)
      expect(prompt.dig(:appointment, 'status')).to eq('confirmed')
      expect(JSON.parse(prompt.dig(:appointment_context_blocks, 'nearest'))['id']).to eq(nearest.id)

      context = instance_double(Captain::Runtime::RunContext, context: { state: { prompt_context: prompt } })
      rendered = assistant.agent_instructions(context)
      expect(rendered).not_to include('Ближайшая запись (данные)', "\"id\":#{nearest.id}", '# Linked Appointment Context')
    end
  end

  describe 'the summary written into the clinic instructions' do
    let(:resource) { create(:scheduling_resource, account: account, name: 'Иванов Алексей Петрович', timezone: 'Asia/Almaty') }
    let(:service) { create(:scheduling_service, account: account, name: 'Приём терапевта (первичный)') }
    let(:description) { 'Текущие записи пациента: [$Сводка](field://appointment.summary). Не записывайте повторно на то же время.' }
    let(:config) { { 'context_access' => { 'appointment' => { 'enabled' => true, 'field_ids' => %w[appointment.summary] } } } }
    let(:clock) do
      { now_utc: '2026-10-12T18:56:00Z', now_local: '2026-10-12T23:56:00+05:00', timezone: 'Asia/Almaty',
        date_local: '2026-10-12', time_local: '23:56:00' }
    end

    def render_prompt(assistant)
      travel_to(Time.zone.parse('2026-10-12 18:56:00 UTC')) do
        state = Captain::ContextFields.runtime_state_for(account: account, conversation: conversation, assistant: assistant)
        state[:runtime_clock] = clock
        state[:prompt_context] = assistant.prompt_context_state(state)
        assistant.agent_instructions(instance_double(Captain::Runtime::RunContext, context: { state: state }))
      end
    end

    before do
      travel_to(Time.zone.parse('2026-10-12 18:56:00 UTC')) do
        create(:scheduling_appointment, account: account, contact: contact, resource: resource, service: service,
                                        starts_at: Time.zone.parse('2026-10-15 05:30:00 UTC'), ends_at: Time.zone.parse('2026-10-15 06:00:00 UTC'))
      end
    end

    it 'writes one short English line with the data values as stored and no internal number or JSON' do
      assistant = create(:captain_assistant, account: account, description: description, config: config)

      rendered = render_prompt(assistant)

      expect(rendered).to include(
        'Текущие записи пациента: upcoming: Thu 15.10.2026 10:30, «Приём терапевта (первичный)», Иванов Алексей Петрович; ' \
        'no past or cancelled appointments. Не записывайте повторно на то же время.'
      )
      expect(rendered).not_to include('"id"', '"groups"', 'details_tool', 'Показано')
      expect(rendered).not_to match(/#\d/)
    end

    it 'writes the number of the appointment only when a tool bound for the run takes it' do
      config_with_tool = config.merge('tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => %w[get_appointment] } })
      assistant = create(:captain_assistant, account: account, description: description, config: config_with_tool)

      appointment_id = account.scheduling_appointments.pick(:id)

      expect(render_prompt(assistant)).to include("upcoming: ##{appointment_id} Thu 15.10.2026 10:30, «Приём терапевта (первичный)»")
    end

    it 'never writes an appointment of another patient who shares the phone of this one' do
      child = create(:contact, account: account)
      other_resource = create(:scheduling_resource, account: account, name: 'Сидорова Мария', timezone: 'Asia/Almaty')
      create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, resource: other_resource,
                                      starts_at: Time.zone.parse('2026-10-16 07:00:00 UTC'), ends_at: Time.zone.parse('2026-10-16 07:30:00 UTC'))
      assistant = create(:captain_assistant, account: account, description: description, config: config)

      rendered = render_prompt(assistant)

      expect(rendered).to include('upcoming: Thu 15.10.2026 10:30')
      expect(rendered).not_to include('Сидорова Мария', 'Fri 16.10.2026')
    end

    it 'keeps the summary in the run data although the text of the prompt only shows it where the clinic referenced it' do
      assistant = create(:captain_assistant, account: account, description: 'No references.', config: config)
      state = Captain::ContextFields.runtime_state_for(account: account, conversation: conversation, assistant: assistant)

      expect(assistant.prompt_context_state(state).dig(:appointment, 'summary', :kind)).to eq('appointments')
      expect(render_prompt(assistant)).not_to include('upcoming:', 'Thu 15.10.2026')
    end
  end

  it 'omits another clinical patient from eager state and every selected context block' do
    travel_to(Time.zone.parse('2026-10-09 12:00:00 UTC')) do
      child = create(:contact, account: account)
      own = create(:scheduling_appointment, account: account, contact: contact, patient_contact: contact,
                                            starts_at: 2.hours.from_now, ends_at: 150.minutes.from_now)
      create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, conversation: conversation,
                                      starts_at: 10.minutes.from_now, ends_at: 40.minutes.from_now)
      create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, conversation: conversation,
                                      starts_at: 1.hour.ago, ends_at: 30.minutes.ago, status: 'completed')
      create(:scheduling_appointment, account: account, contact: contact, patient_contact: child, conversation: conversation,
                                      starts_at: 1.day.from_now, ends_at: 1.day.from_now + 30.minutes, status: 'cancelled')
      config = {
        'context_access' => {
          'appointment' => {
            'enabled' => true,
            'field_ids' => %w[appointment.nearest appointment.last_past appointment.last_cancelled appointment.all appointment.status]
          }
        }
      }
      assistant = create(:captain_assistant, account: account, usage_mode: 'external_agent', config: config)
      state = Captain::ContextFields.runtime_state_for(account: account, conversation: conversation, assistant: assistant)
      blocks = assistant.prompt_context_state(state).fetch(:appointment_context_blocks)

      expect(state.dig(:appointment, :id)).to eq(own.id)
      expect(JSON.parse(blocks.fetch('nearest')).fetch('id')).to eq(own.id)
      expect(JSON.parse(blocks.fetch('last_past'))).to be_nil
      expect(JSON.parse(blocks.fetch('last_cancelled'))).to be_nil
      expect(JSON.parse(blocks.fetch('all'))).to include('total' => 1)
      expect(JSON.parse(blocks.fetch('all')).fetch('appointments').pluck('id')).to eq([own.id])
    end
  end
end
