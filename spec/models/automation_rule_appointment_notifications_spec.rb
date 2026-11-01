require 'rails_helper'

RSpec.describe AutomationRule do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }

  def build_rule(params, active: false)
    build(:automation_rule, account: account, event_name: 'appointment_created', active: active,
                            conditions: [], actions: [{ action_name: 'create_touch', action_params: params }])
  end

  ['true', '1', 1].each do |value|
    it "drops a blank-time override expressed as #{value}" do
      rule = build_rule({ timing_mode: 'absolute', scheduled_at: '', manual_schedule_override: value, body: 'Visit' })
      rule.save!
      expect(rule.reload.actions.first['action_params']).not_to have_key('manual_schedule_override')
    end
  end

  it 'drops the flag for a true boolean in array parameters and sets the account timezone' do
    rule = build_rule([{ timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
                         relative_offset_seconds: -3600, scheduled_at: nil, manual_schedule_override: true,
                         timezone: 'Europe/Berlin', body: 'Visit' }])
    rule.save!
    params = rule.reload.actions.first['action_params'].first
    expect(params).not_to have_key('manual_schedule_override')
    expect(params['timezone']).to eq(account.workspace_working_hours_timezone)
  end

  it 'keeps an override when a real time is present' do
    rule = build_rule({ timing_mode: 'absolute', scheduled_at: 2.days.from_now.iso8601,
                        manual_schedule_override: true, body: 'Visit' })
    rule.save!
    expect(rule.reload.actions.first['action_params']['manual_schedule_override']).to be true
  end

  it 'normalizes the timezone on a saved active rule without changing its field references' do
    account.update!(workspace_timezone: 'Asia/Aqtobe')
    rule = build_rule({ body: 'Hello', timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
                        relative_offset_seconds: -3600, timezone: 'Europe/Berlin' })
    rule.save!
    expect(rule.reload.actions.first['action_params']['timezone']).to eq(account.workspace_working_hours_timezone)
  end

  describe 'min_minutes_before_appointment' do
    it 'stores and syncs positive integer values across execution_schedule and touch action_params' do
      rule = build_rule([{ timing_mode: 'relative', relative_anchor: 'touch.created_at',
                           relative_offset_seconds: 60, body: 'Booked' }])
      rule.min_minutes_before_appointment = '60'
      rule.save!
      rule.reload

      expect(rule.min_minutes_before_appointment).to eq(60)
      expect(rule.execution_schedule['min_minutes_before_appointment']).to eq(60)
      expect(rule.actions.first['action_params'].first['min_minutes_before_appointment']).to eq(60)
    end

    it 'syncs min_minutes_before_appointment submitted inside touch action_params and clears when blank' do
      rule = build_rule([{ timing_mode: 'relative', relative_anchor: 'touch.created_at',
                           relative_offset_seconds: 60, min_minutes_before_appointment: '45', body: 'Booked' }])
      rule.save!
      expect(rule.reload.min_minutes_before_appointment).to eq(45)

      rule.update!(min_minutes_before_appointment: '')
      rule.reload
      expect(rule.min_minutes_before_appointment).to be_nil
      expect(rule.execution_schedule).not_to have_key('min_minutes_before_appointment')
      expect(rule.actions.first['action_params'].first).not_to have_key('min_minutes_before_appointment')
    end

    it 'preserves min_minutes_before_appointment across partial updates and duplication' do
      rule = build_rule([{ timing_mode: 'relative', relative_anchor: 'touch.created_at',
                           relative_offset_seconds: 60, body: 'Booked' }])
      rule.min_minutes_before_appointment = 60
      rule.save!
      rule.update!(active: true)

      cloned = rule.dup
      cloned.save!
      expect(rule.reload.min_minutes_before_appointment).to eq(60)
      expect(cloned.reload.min_minutes_before_appointment).to eq(60)
    end

    [0, -15, 'abc', 1.5, '1.5', 43_201].each do |invalid_value|
      it "rejects invalid min_minutes_before_appointment value #{invalid_value.inspect}" do
        rule = build_rule({ timing_mode: 'relative', relative_anchor: 'touch.created_at',
                            relative_offset_seconds: 60, body: 'Booked' })
        rule.min_minutes_before_appointment = invalid_value

        expect(rule).not_to be_valid
        expect(rule.errors[:min_minutes_before_appointment]).to be_present
      end
    end

    it 'rejects invalid min_minutes_before_appointment inside create_touch action_params' do
      rule = build_rule([{ timing_mode: 'relative', relative_anchor: 'touch.created_at',
                           relative_offset_seconds: 60, min_minutes_before_appointment: -5, body: 'Booked' }])

      expect(rule).not_to be_valid
      expect(rule.errors[:min_minutes_before_appointment]).to be_present
    end

    it 'rejects non-blank min_minutes_before_appointment on non-appointment events' do
      rule = build(:automation_rule, account: account, event_name: 'conversation_created',
                                     conditions: [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil }],
                                     actions: [{ action_name: 'send_message', action_params: ['Hi'] }])
      rule.min_minutes_before_appointment = 60

      expect(rule).not_to be_valid
      expect(rule.errors[:min_minutes_before_appointment]).to be_present
    end
  end
end
