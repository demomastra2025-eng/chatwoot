require 'rails_helper'
require 'timeout'

RSpec.describe Reminders::SyncRemindableService do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:old_owner) { create(:user, account: account, role: :agent) }
  let(:new_owner) { create(:user, account: account, role: :agent) }
  let(:creator) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, owner: old_owner) }
  let(:appointment) do
    create(:scheduling_appointment, account: account, contact: contact, created_by: creator, owner_id: creator.id)
  end

  after do
    Reminder.where(account_id: account.id).delete_all
    Scheduling::Appointment.where(account_id: account.id).destroy_all
    Scheduling::Resource.where(account_id: account.id).destroy_all
    Scheduling::Service.where(account_id: account.id).destroy_all
    account.destroy! if Account.exists?(account.id)
  end

  def pid
    ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
  end

  def wait_until_blocked!(waiting_pid, blocker_pid)
    Timeout.timeout(15) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{waiting_pid})")
        break if blockers.include?(blocker_pid.to_s)

        sleep 0.01
      end
    end
  end

  it 'waits for a Contact transfer before inserting an appointment reminder' do
    appointment
    held = Queue.new
    release = Queue.new
    transfer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        locked = Contact.find(contact.id)
        locked.with_lock do
          locked.update!(owner: new_owner)
          held << pid
          release.pop
        end
      end
    end
    transfer_pid = Timeout.timeout(15) { held.pop }
    started = Queue.new
    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << pid
        Reminders::CreateService.new(account: account, remindable: Scheduling::Appointment.find(appointment.id),
                                     attributes: { body: 'Visit', scheduled_at: 2.days.from_now }).perform
      end
    end
    creation_pid = Timeout.timeout(15) { started.pop }
    wait_until_blocked!(creation_pid, transfer_pid)
    release << true
    Timeout.timeout(15) { transfer.value }
    reminder = Timeout.timeout(15) { creation.value }

    expect(reminder.reload.owner).to eq(new_owner)
    expect(appointment.reload.owner_id).to eq(creator.id)
  ensure
    release&.push(true)
    [transfer, creation].compact.each { |worker| Timeout.timeout(15) { worker.value } if worker.alive? }
  end

  it 'locks Contact before Reminder during resync, so transfer cannot invert the order' do
    reminder = create(:reminder, account: account, remindable: appointment,
                                 body: 'Visit', scheduled_at: 2.days.from_now)
    held = Queue.new
    release = Queue.new
    locker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Reminder.find(reminder.id).with_lock do
          held << pid
          release.pop
        end
      end
    end
    reminder_pid = Timeout.timeout(15) { held.pop }
    sync_started = Queue.new
    sync = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        sync_started << pid
        described_class.new(remindable: Scheduling::Appointment.find(appointment.id))
                       .perform_for(Reminder.find(reminder.id), raise_errors: true)
      end
    end
    sync_pid = Timeout.timeout(15) { sync_started.pop }
    wait_until_blocked!(sync_pid, reminder_pid)

    transfer_started = Queue.new
    transfer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        transfer_started << pid
        Contact.find(contact.id).update!(owner: new_owner)
      end
    end
    transfer_pid = Timeout.timeout(15) { transfer_started.pop }
    wait_until_blocked!(transfer_pid, sync_pid)
    release << true
    Timeout.timeout(15) { [locker, sync, transfer].each(&:value) }

    expect(reminder.reload.owner).to eq(new_owner)
    expect(appointment.reload.owner_id).to eq(creator.id)
  ensure
    release&.push(true)
    [locker, sync, transfer].compact.each { |worker| Timeout.timeout(15) { worker.value } if worker.alive? }
  end

  it 'serializes a contact transfer with an appointment rebind and keeps the destination owner' do
    replacement = create(:contact, account: account, owner: creator)
    reminder = create(:reminder, account: account, remindable: appointment, body: 'Visit', scheduled_at: 2.days.from_now)
    held = Queue.new
    release = Queue.new
    transfer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        locked = Contact.find(contact.id)
        locked.with_lock do
          locked.update!(owner: new_owner)
          held << pid
          release.pop
        end
      end
    end
    transfer_pid = Timeout.timeout(15) { held.pop }
    started = Queue.new
    rebind = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << pid
        Scheduling::Appointments::UpsertService.new(
          account: account, appointment: Scheduling::Appointment.find(appointment.id),
          params: { contact_id: replacement.id, client_comment: 'rebound' }
        ).perform
      end
    end
    rebind_pid = Timeout.timeout(15) { started.pop }
    wait_until_blocked!(rebind_pid, transfer_pid)
    release << true
    Timeout.timeout(15) { [transfer, rebind].each(&:value) }

    expect(appointment.reload.contact_id).to eq(replacement.id)
    expect(reminder.reload).to have_attributes(owner_id: creator.id, target_contact_id: replacement.id)
  ensure
    release&.push(true)
    [transfer, rebind].compact.each { |worker| Timeout.timeout(15) { worker.value } if worker.alive? }
  end

  it 'syncs a direct contact rebind before the appointment transaction commits' do
    replacement = create(:contact, account: account, owner: new_owner)
    reminder = create(:reminder, account: account, remindable: appointment, body: 'Visit', scheduled_at: 2.days.from_now)

    Scheduling::Appointment.transaction do
      Scheduling::Appointment.find(appointment.id).update!(contact: replacement)
      expect(Reminder.find(reminder.id)).to have_attributes(owner_id: new_owner.id, target_contact_id: replacement.id)
    end
  end

  it 'rolls back a direct rebind if its reminder cannot be synchronized' do
    replacement = create(:contact, account: account, owner: new_owner)
    reminder = create(:reminder, account: account, remindable: appointment, body: 'Visit', scheduled_at: 2.days.from_now)
    allow(described_class).to receive(:new).and_wrap_original do |original, **kwargs|
      service = original.call(**kwargs)
      allow(service).to receive(:sync_locked_touch!).and_raise(StandardError, 'sync rejected')
      service
    end

    expect do
      Scheduling::Appointment.find(appointment.id).update!(contact: replacement)
    end.to raise_error(StandardError, 'sync rejected')

    expect(appointment.reload.contact_id).to eq(contact.id)
    expect(reminder.reload.target_contact_id).to eq(contact.id)
  end

  it 'does not invert Contact and Reminder locks during deferred reminder reconciliation' do
    reminder = create(:reminder, account: account, remindable: appointment, body: 'Visit', scheduled_at: 2.days.from_now)
    enrollment = Struct.new(:remindable).new(Scheduling::Appointment.find(appointment.id))
    service = Reminders::SyncMaterializedEnrollmentReminderService.new(
      enrollment: enrollment, claim: nil, reminder: reminder, step: nil
    )
    held = Queue.new
    release = Queue.new
    allow(service).to receive(:sync_definition!) do
      held << pid
      release.pop
    end

    reconciliation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { ApplicationRecord.transaction { service.perform } }
    end
    reconciliation_pid = Timeout.timeout(15) { held.pop }
    started = Queue.new
    transfer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << pid
        Contact.find(contact.id).update!(owner: new_owner)
      end
    end
    transfer_pid = Timeout.timeout(15) { started.pop }
    wait_until_blocked!(transfer_pid, reconciliation_pid)
    release << true
    Timeout.timeout(15) { [reconciliation, transfer].each(&:value) }

    expect(reminder.reload.owner).to eq(new_owner)
  ensure
    release&.push(true)
    [reconciliation, transfer].compact.each { |worker| Timeout.timeout(15) { worker.value } if worker.alive? }
  end

  it 'does not deadlock a scheduled touch against conversation linking for the same contact' do
    conversation = create(:conversation, account: account, contact: contact)
    reminder = create(:reminder, account: account, remindable: appointment, touch_conversation: conversation,
                                 body: 'Visit', scheduled_at: 2.days.from_now)
    held = Queue.new
    release = Queue.new
    execution = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Scheduling::Appointment.find(appointment.id).with_lock do
          held << pid
          release.pop
          Reminders::MessageMaterializer.new(reminder: Reminder.find(reminder.id))
                                        .perform(conversation: conversation, sender: old_owner, content: 'Visit')
        end
      end
    end
    execution_pid = Timeout.timeout(15) { held.pop }
    linker_started = Queue.new
    linker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ApplicationRecord.transaction do
          Conversations::CommunicationThreadResolver.lock_contact_thread!(account.id, contact.id)
          linker_started << pid
          Scheduling::Appointment.find(appointment.id).with_lock { true }
        end
      end
    end
    linker_pid = Timeout.timeout(15) { linker_started.pop }
    wait_until_blocked!(linker_pid, execution_pid)
    release << true
    message = Timeout.timeout(15) { execution.value }
    Timeout.timeout(15) { linker.value }
    expect(message).to be_persisted
  ensure
    release&.push(true)
    [execution, linker].compact.each { |worker| Timeout.timeout(15) { worker.value } if worker.alive? }
  end
end
