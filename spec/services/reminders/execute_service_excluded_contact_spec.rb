require 'rails_helper'

# A touch an automation rule scheduled is held to the rule's "Contact is not" list when it is sent.
RSpec.describe Reminders::ExecuteService do
  let(:account) { create(:account, limits: { non_web_inboxes: 10 }).tap { |record| record.enable_features!('scheduling') } }
  let(:inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:contact) { create(:contact, account: account, name: 'Owner', phone_number: '+77000000001') }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: '77000000001') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, conversation: conversation,
                                    starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
  end
  let(:status_condition) do
    { 'attribute_key' => 'status', 'filter_operator' => 'equal_to', 'values' => [appointment.status], 'query_operator' => nil }
  end
  let(:rule) do
    create(
      :automation_rule,
      account: account,
      event_name: 'appointment_created',
      conditions: [status_condition],
      actions: [{
        action_name: 'create_touch',
        action_params: {
          body: 'Visit reminder',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -1.hour.to_i,
          timezone: 'UTC'
        }
      }]
    )
  end

  def exclude!(ids)
    conditions = [
      status_condition.merge('query_operator' => 'AND'),
      { 'attribute_key' => 'contact_id', 'filter_operator' => 'not_equal_to', 'values' => ids, 'query_operator' => nil }
    ]
    rule.update_columns(conditions: conditions) # rubocop:disable Rails/SkipsModelValidations
  end

  def scheduled_touch
    AutomationRules::AppointmentActionService.new(rule, account, appointment).perform
    account.reminders.where(remindable: appointment).sole
  end

  # A touch whose chat was just resolved is re-queued once by the live refresh; the next claim delivers it.
  def run(touch)
    travel_to(touch.scheduled_at + 1.minute) do
      2.times do
        described_class.new(reminder: touch.reload, processing_claim: touch.mark_processing!).perform
        break unless touch.reload.pending?
      end
    end
    touch.reload
  end

  it 'sends the touch while its contact is not excluded' do
    touch = scheduled_touch

    expect { run(touch) }.to change { conversation.messages.outgoing.count }.by(1)
    expect(touch).to be_completed
  end

  it 'cancels the touch instead of sending it once its contact is excluded', :aggregate_failures do
    touch = scheduled_touch
    exclude!([contact.id])

    expect { run(touch) }.not_to(change { Message.outgoing.count })

    expect(touch).to have_attributes(status: 'cancelled', last_error: Reminders::ExcludedContactPolicy::CANCEL_REASON)
    expect(touch.metadata).to include('cancelled_via' => Reminders::ExcludedContactPolicy::CANCELLED_VIA)
  end

  it 'sends the touch of a contact the list does not name' do
    touch = scheduled_touch
    exclude!([create(:contact, account: account).id])

    expect { run(touch) }.to change { conversation.messages.outgoing.count }.by(1)
    expect(touch).to be_completed
  end

  it 'checks the contact the route was re-pointed to, not only the one the touch was made for' do
    touch = scheduled_touch
    holder = create(:contact, account: account, name: 'Holder', phone_number: '+77000000003')
    exclude!([holder.id])
    route = Reminders::PatientSubjectGuard::Route.new(contact: holder, conversation: nil, kind: :holder)
    allow(Reminders::PatientSubjectGuard).to receive(:notification_route).and_return(route)

    expect { run(touch) }.not_to(change { Message.outgoing.count })

    expect(touch).to have_attributes(status: 'cancelled', target_contact_id: holder.id)
  end
end
