require 'rails_helper'

RSpec.describe Captain::Assistant, type: :model do
  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }

  before { account.enable_features!('scheduling') }

  it 'recommends three blocks only on creation with scheduling tools' do
    config = {
      'tool_access' => { 'agent' => { 'enabled' => true, 'tool_ids' => ['list_my_appointments'] } },
      'context_access' => {}
    }
    assistant = create(:captain_assistant, account: account, config: config)
    expect(assistant.config.dig('context_access', 'appointment')).to eq(
      'enabled' => true,
      'field_ids' => %w[appointment.nearest appointment.last_past appointment.last_cancelled]
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
      expect(rendered).to include('Ближайшая запись (данные): {')
      expect(rendered).to include("\"id\":#{nearest.id}")
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
