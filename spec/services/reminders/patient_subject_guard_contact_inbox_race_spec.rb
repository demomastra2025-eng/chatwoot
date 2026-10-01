require 'rails_helper'
require 'timeout'

# A second worker (another touch, an appointment sync or an inbound message from the patient's own number) can insert
# the SAME patient's ContactInbox concurrently. The losing insert must reuse that ContactInbox instead of turning the
# own-number touch into a failure or a reassignment draft.
RSpec.describe Reminders::PatientSubjectGuard do
  self.use_transactional_tests = false

  let(:account) { create(:account, limits: { non_web_inboxes: 10 }).tap { |record| record.enable_features!('scheduling') } }
  let(:inbox) { create(:channel_whatsapp_web, account: account).inbox }
  let(:owner) { create(:contact, account: account, name: 'Owner', phone_number: '+77000000001') }
  let(:owner_contact_inbox) { create(:contact_inbox, contact: owner, inbox: inbox, source_id: '77000000001') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: owner, contact_inbox: owner_contact_inbox) }
  let(:patient) { create(:contact, account: account, name: 'Relative', phone_number: nil) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: owner, patient_contact: patient, conversation: conversation, service: nil,
                                    client_name: 'Relative Patient', starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
  end
  let(:own_number) { '+77000000002' }

  after { cleanup_account(account) }

  it 'lets the resolver reuse the same patient ContactInbox inserted by a concurrent worker' do
    patient.update!(phone_number: own_number)
    touch = Reminder.new(account: account, target_inbox: inbox, target_contact: patient, remindable: appointment, body: 'Hi')

    result = race_with_uncommitted_contact_inbox(patient) { Reminders::ConversationResolver.new(reminder: touch).perform }

    expect(result).to be_a(Conversation)
    expect(result.contact_inbox).to have_attributes(contact_id: patient.id, source_id: '77000000002')
    expect(result.contact_id).to eq(patient.id)
    expect(ContactInbox.where(inbox: inbox, contact: patient).count).to eq(1)
  end

  it 'delivers an own-number touch when the same patient ContactInbox is inserted concurrently' do
    touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation,
                              remindable: appointment, status: :processing, body: 'Visit reminder')
    patient.update!(phone_number: own_number)

    result = race_with_uncommitted_contact_inbox(patient) do
      Reminders::ExecuteService.new(reminder: Reminder.find(touch.id)).perform
      :performed
    end

    expect(result).to eq(:performed)
    expect(touch.reload).to be_completed
    own_contact_inbox = ContactInbox.find_by!(inbox: inbox, contact: patient)
    expect(touch).to have_attributes(target_contact_id: patient.id, target_contact_inbox_id: own_contact_inbox.id)
    expect(conversation.messages.outgoing.count).to eq(0)
  end

  it 'keeps a synced touch deliverable when the same patient ContactInbox is inserted concurrently' do
    touch = create(:reminder, account: account, remindable: appointment, conversation: conversation, status: :pending)
    patient.update!(phone_number: own_number)

    result = race_with_uncommitted_contact_inbox(patient) do
      Reminders::SyncRemindableService.new(remindable: Scheduling::Appointment.find(appointment.id)).perform
      :synced
    end

    expect(result).to eq(:synced)
    own_contact_inbox = ContactInbox.find_by!(inbox: inbox, contact: patient)
    expect(touch.reload).to have_attributes(status: 'pending', target_contact_id: patient.id, target_contact_inbox_id: own_contact_inbox.id)
    expect(touch).not_to be_route_reassignment_required
  end

  it 'still refuses a source that a concurrent worker gave to another contact' do
    stranger = create(:contact, account: account, name: 'Stranger', phone_number: nil)
    patient.update!(phone_number: own_number)
    touch = Reminder.new(account: account, target_inbox: inbox, target_contact: patient, remindable: appointment, body: 'Hi')

    result = race_with_uncommitted_contact_inbox(stranger) { Reminders::ConversationResolver.new(reminder: touch).perform }

    expect(result).to be_a(Reminders::UndeliverableTargetError)
    expect(result.message).to eq(Reminders::ConversationResolver::PATIENT_NUMBER_TAKEN)
    expect(ContactInbox.find_by!(inbox: inbox, source_id: '77000000002').contact_id).to eq(stranger.id)
  end

  it 'propagates database errors other than a lost insert race' do
    patient.update!(phone_number: own_number)

    expect do
      described_class.own_contact_inbox(inbox: inbox, contact: patient, source_id: '77000000002') do
        raise ActiveRecord::Deadlocked, 'deadlock detected'
      end
    end.to raise_error(ActiveRecord::Deadlocked)
  end

  # The winner inserts the ContactInbox and keeps its transaction open until the loser waits on the unique index.
  def race_with_uncommitted_contact_inbox(contact, &)
    inserted = Queue.new
    release = Queue.new
    backend = Queue.new
    outcome = Queue.new
    winner = hold_uncommitted_contact_inbox(contact, inserted, release)
    Timeout.timeout(10) { inserted.pop }
    loser = run_loser(backend, outcome, &)
    wait_for_lock_wait(Timeout.timeout(10) { backend.pop })
    release << true
    [winner, loser].each { |worker| Timeout.timeout(20) { worker.join } }
    outcome.pop
  ensure
    release << true if release&.num_waiting&.positive?
  end

  def hold_uncommitted_contact_inbox(contact, inserted, release)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          ContactInbox.create!(contact_id: contact.id, inbox_id: inbox.id, source_id: '77000000002')
          inserted << true
          release.pop
        end
      end
    end
  end

  def run_loser(backend, outcome)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend << connection.select_value('SELECT pg_backend_pid()')
        outcome << yield
      end
    rescue StandardError => e
      outcome << e
    end
  end

  def wait_for_lock_wait(backend_pid)
    Timeout.timeout(10) do
      loop do
        waiting = ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM pg_locks WHERE pid = #{Integer(backend_pid)} AND NOT granted"
        ).to_i
        break if waiting.positive?

        sleep 0.02
      end
    end
  end

  def cleanup_account(record)
    return unless record.persisted?

    delete_conversation_records(record.id)
    delete_contact_records(record.id)
    record.reload.destroy!
  end

  def delete_conversation_records(account_id)
    conversation_ids = Conversation.where(account_id: account_id).pluck(:id)
    Message.where(account_id: account_id).delete_all
    Reminder.where(account_id: account_id).delete_all
    Scheduling::Appointment.where(account_id: account_id).delete_all
    CommunicationThreadConversation.where(conversation_id: conversation_ids).delete_all
    ConversationStatusTransition.where(conversation_id: conversation_ids).delete_all
    Conversation.where(id: conversation_ids).delete_all
  end

  def delete_contact_records(account_id)
    ContactChannelProfile.where(account_id: account_id).delete_all
    ContactInbox.where(inbox_id: Inbox.where(account_id: account_id).select(:id)).delete_all
    CommunicationThread.where(account_id: account_id).delete_all
    Contact.where(account_id: account_id).delete_all
    Scheduling::Resource.where(account_id: account_id).delete_all
  end
end
