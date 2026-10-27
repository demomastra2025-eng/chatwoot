require 'rails_helper'

RSpec.describe AutomationRule do
  let(:account) { create(:account) }

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
end
