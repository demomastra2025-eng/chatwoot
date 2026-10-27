require 'rails_helper'

RSpec.describe AutomationRule do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:action) do
    {
      action_name: 'create_touch',
      action_params: {
        body: '[Услуга](field://appointment.service_name_snapshot)',
        timing_mode: 'relative', relative_anchor: 'appointment.starts_at', relative_offset_seconds: -3600
      }
    }
  end
  let(:conditions) do
    [{ attribute_key: 'source', filter_operator: 'is_present', values: [], query_operator: nil }]
  end

  before do
    create(:scheduling_appointment, account: account, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes,
                                    service_name_snapshot: nil)
  end

  it 'blocks an active new rule that uses a mostly empty field' do
    rule = build(:automation_rule, account: account, active: true, event_name: 'appointment_created', conditions: conditions, actions: [action])
    expect(rule).not_to be_valid
    expect(rule.errors[:actions].join).to include('Услуга')
  end

  it 'allows deactivation and unrelated edits of a stored rule' do
    stats = instance_double(Scheduling::TemplateFieldFillStats, perform: [])
    allow(Scheduling::TemplateFieldFillStats).to receive(:new).and_return(stats)
    rule = create(:automation_rule, account: account, active: true, event_name: 'appointment_created', conditions: conditions, actions: [action])
    allow(Scheduling::TemplateFieldFillStats).to receive(:new).and_call_original
    rule.update!(name: 'Renamed')
    rule.update!(active: false)
    rule.update!(active: false, description: 'Edited')
    expect(rule.reload.name).to eq('Renamed')
  end

  it 'blocks activation but allows an active rule to change to a safe field' do
    rule = create(:automation_rule, account: account, active: false, event_name: 'appointment_created', conditions: conditions, actions: [action])
    expect(rule.update(active: true)).to be false
    safe = action.deep_dup
    safe[:action_params][:body] = '[Имя](field://appointment.client_name)'
    expect(rule.update(actions: [safe], active: true)).to be true
  end
end
