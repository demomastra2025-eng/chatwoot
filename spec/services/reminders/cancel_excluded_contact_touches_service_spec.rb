require 'rails_helper'

RSpec.describe Reminders::CancelExcludedContactTouchesService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:excluded) { create(:contact, account: account, name: 'Excluded') }
  let(:friend) { create(:contact, account: account, name: 'Friend') }
  let(:rule) do
    create(:automation_rule, account: account, event_name: 'conversation_updated', conditions: [],
                             actions: [{ action_name: 'create_touch', action_params: { body: 'Follow-up', delay_minutes: 30 } }])
  end

  def conversation_for(contact)
    create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox))
  end

  def touch_for(contact, source_rule = rule)
    AutomationRules::TouchActionService.new(rule: source_rule, account: account, record: conversation_for(contact), entity_kind: 'conversation')
                                       .create_touch(body: 'Follow-up', delay_minutes: 30)
  end

  def contact_list(operator, contacts)
    [{ 'attribute_key' => 'contact_id', 'filter_operator' => operator, 'values' => contacts.map(&:id), 'query_operator' => nil }]
  end

  def exclude!(*contacts)
    rule.update_columns(conditions: contact_list('not_equal_to', contacts)) # rubocop:disable Rails/SkipsModelValidations
  end

  it 'cancels the open touches of excluded contacts only and counts them', :aggregate_failures do
    excluded_touch = touch_for(excluded)
    draft_touch = touch_for(excluded).tap { |touch| touch.update_columns(status: Reminder.statuses[:draft]) } # rubocop:disable Rails/SkipsModelValidations
    friend_touch = touch_for(friend)
    exclude!(excluded)

    expect(described_class.new(rule: rule.reload).perform).to eq(2)

    expect(excluded_touch.reload).to be_cancelled
    expect(draft_touch.reload).to be_cancelled
    expect(friend_touch.reload).to be_pending
  end

  it 'leaves touches that are being sent, finished, or from another rule alone', :aggregate_failures do
    sending = touch_for(excluded)
    sending.mark_processing!
    other_rule = create(:automation_rule, account: account, event_name: 'conversation_updated', conditions: [],
                                          actions: [{ action_name: 'create_touch', action_params: { body: 'Other', delay_minutes: 30 } }])
    other_touch = touch_for(excluded, other_rule)
    exclude!(excluded)

    expect(described_class.new(rule: rule.reload).perform).to eq(0)

    expect(sending.reload).to be_processing
    expect(other_touch.reload).to be_pending
  end

  it 'does nothing for a rule without an "is not" list' do
    touch = touch_for(excluded)
    rule.update_columns(conditions: contact_list('equal_to', [friend])) # rubocop:disable Rails/SkipsModelValidations

    expect(described_class.new(rule: rule.reload).perform).to eq(0)
    expect(touch.reload).to be_pending
  end

  it 'keeps going when one touch cannot be cancelled' do
    broken = touch_for(excluded)
    healthy = touch_for(excluded)
    exclude!(excluded)
    tracker = instance_double(ChatwootExceptionTracker, capture_exception: nil)
    allow(ChatwootExceptionTracker).to receive(:new).and_return(tracker)
    allow(Reminders::ExcludedContactPolicy).to receive(:new).and_wrap_original do |original, **kwargs|
      raise ActiveRecord::StatementInvalid, 'boom' if kwargs[:reminder].id == broken.id

      original.call(**kwargs)
    end

    expect(described_class.new(rule: rule.reload).perform).to eq(1)

    expect(broken.reload).to be_pending
    expect(healthy.reload).to be_cancelled
    expect(tracker).to have_received(:capture_exception)
  end
end
