require 'rails_helper'

RSpec.describe Reminders::CancelRuleTouchesService do
  let(:account) { create(:account).tap { |record| record.enable_features!('scheduling') } }
  let(:rule) do
    create(:automation_rule, account: account, active: true, event_name: 'appointment_created', conditions: [],
                             actions: [{ action_name: 'create_touch', action_params: {
                               body: 'Visit', timing_mode: 'relative', relative_anchor: 'appointment.starts_at',
                               relative_offset_seconds: -3600
                             } }])
  end
  let(:conversation) { create(:conversation, account: account) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: conversation.contact, conversation: conversation,
                                    starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
  end

  def rule_touch(target_rule = rule, body: 'Visit')
    create(:reminder, account: account, remindable: appointment, touch_conversation: conversation, body: body).tap do |touch|
      touch.mark_automation_provenance!(target_rule, action_key: target_rule.actions.first['action_id'])
    end
  end

  it 'cancels a direct open reminder immediately when its rule turns off' do
    touch = rule_touch
    rule.update!(active: false)
    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq('automation_rule_inactive')
  end

  it 'cancels an open reminder when its action is removed, preserving another rule' do
    touch = rule_touch
    other_rule = create(:automation_rule, account: account)
    other_touch = rule_touch(other_rule, body: 'Other notification')
    rule.update!(actions: [])
    expect(touch.reload).to be_cancelled
    expect(other_touch.reload).to be_pending
  end

  it 'does not cancel a delivery-materialized processing reminder' do
    touch = rule_touch
    touch.update!(status: :processing)
    touch.mark_delivery_materialized!(123)
    rule.update!(active: false)
    expect(touch.reload).to be_processing
  end

  it 'cancels direct reminders before the rule is deleted' do
    touch = rule_touch
    rule.destroy!
    expect(touch.reload).to be_cancelled
    expect(touch.last_error).to eq('automation_rule_deleted')
  end
end
