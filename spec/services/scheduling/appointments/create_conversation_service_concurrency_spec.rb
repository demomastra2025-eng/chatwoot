require 'rails_helper'
require 'timeout'

RSpec.describe Scheduling::Appointments::CreateConversationService do
  self.use_transactional_tests = false

  let(:account) { create(:account) }
  let(:contact) { create(:contact, account: account) }
  let(:inbox) { create(:inbox, account: account, channel: create(:channel_api, account: account)) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:appointment) { create(:scheduling_appointment, account: account, contact: contact) }
  let(:creator) { create(:user, account: account, role: :agent) }
  let(:new_owner) { create(:user, account: account, role: :agent) }

  after do
    appointment.destroy! if Scheduling::Appointment.exists?(appointment.id)
    Conversation.where(account_id: account.id).find_each(&:destroy!)
    ContactChannelProfile.where(account_id: account.id).destroy_all
    ContactInbox.where(contact_id: contact.id).destroy_all
    Scheduling::Resource.where(account_id: account.id).destroy_all
    Scheduling::Service.where(account_id: account.id).destroy_all
    account.destroy! if Account.exists?(account.id)
  end

  def pause_after_lock(record, held, release)
    paused = false
    record.define_singleton_method(:lock!) do |*args, **kwargs|
      super(*args, **kwargs).tap do
        unless paused
          paused = true
          held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          release.pop
        end
      end
    end
  end

  def wait_until_blocked!(blocked_pid, blocker_pid)
    Timeout.timeout(15) do
      loop do
        blockers = ActiveRecord::Base.connection.select_value("SELECT pg_blocking_pids(#{blocked_pid})")
        break if blockers.include?(blocker_pid.to_s)

        sleep 0.01
      end
    end
  end

  it 'serializes conversation creation and a concurrent contact owner change without losing the link' do
    contact_inbox
    new_owner
    held = Queue.new
    release = Queue.new
    record = Scheduling::Appointment.find(appointment.id)
    pause_after_lock(record, held, release)
    service = described_class.new(
      account: account, appointment: record, inbox: inbox,
      params: { contact_id: contact.id, contact_inbox_id: contact_inbox.id, inbox_id: inbox.id }, actor: creator
    )

    creator_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { service.perform }
    rescue StandardError => e
      e
    end
    creator_pid = Timeout.timeout(15) { held.pop }
    owner_started = Queue.new
    owner_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        owner_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        Contact.find(contact.id).update!(owner: new_owner)
      end
    rescue StandardError => e
      e
    end
    owner_pid = Timeout.timeout(15) { owner_started.pop }
    wait_until_blocked!(owner_pid, creator_pid)
    release << true
    creation = Timeout.timeout(15) { creator_thread.value }
    ownership = Timeout.timeout(15) { owner_thread.value }
    raise creation if creation.is_a?(StandardError)
    raise ownership if ownership.is_a?(StandardError)

    expect(Conversation.where(account: account, contact: contact).count).to eq(1)
    expect(appointment.reload).to have_attributes(conversation_id: creation.conversation_id, owner_id: new_owner.id)
    expect(contact.reload.owner_id).to eq(new_owner.id)
    expect(Conversation.find(creation.conversation_id).assignee_id).to eq(new_owner.id)
    events = AutomationEvent.where(account_id: account.id, subject_type: 'Scheduling::Appointment',
                                   subject_id: appointment.id, event_name: 'appointment_updated').order(:id)
    expect(events.count).to eq(2)
    expect(events.first.changes_snapshot).to include('conversation_id' => [nil, creation.conversation_id])
    expect(events.last.changes_snapshot).to include('owner_id' => [creator.id, new_owner.id])
  ensure
    release&.push(true)
    [creator_thread, owner_thread].compact.each do |thread|
      Timeout.timeout(15) { thread.value } if thread.alive?
    end
  end

  it 'rolls back a new ContactInbox when another request links the same appointment first' do
    held = Queue.new
    release = Queue.new
    record = Scheduling::Appointment.find(appointment.id)
    pause_after_lock(record, held, release)
    params = { contact_id: contact.id, inbox_id: inbox.id }
    first_service = described_class.new(account: account, appointment: record, inbox: inbox, params: params, actor: creator)
    second_service = described_class.new(
      account: account, appointment: Scheduling::Appointment.find(appointment.id), inbox: inbox, params: params, actor: creator
    )
    creator_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { first_service.perform }
    rescue StandardError => e
      e
    end
    creator_pid = Timeout.timeout(15) { held.pop }
    retry_started = Queue.new
    retry_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        retry_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        second_service.perform
      end
    rescue StandardError => e
      e
    end
    retry_pid = Timeout.timeout(15) { retry_started.pop }
    wait_until_blocked!(retry_pid, creator_pid)
    release << true
    creation = Timeout.timeout(15) { creator_thread.value }
    retry_result = Timeout.timeout(15) { retry_thread.value }
    raise creation if creation.is_a?(StandardError)
    raise retry_result if retry_result.is_a?(StandardError)

    expect(retry_result.conversation_id).to eq(creation.conversation_id)
    expect(Conversation.where(account: account, contact: contact).count).to eq(1)
    expect(ContactInbox.where(contact: contact, inbox: inbox).count).to eq(1)
    expect(appointment.reload).to have_attributes(conversation_id: creation.conversation_id, owner_id: creator.id)
    expect(AutomationEvent.where(subject_type: 'Scheduling::Appointment', subject_id: appointment.id,
                                 event_name: 'appointment_updated').count).to eq(1)
  ensure
    release&.push(true)
    [creator_thread, retry_thread].compact.each do |thread|
      Timeout.timeout(15) { thread.value } if thread.alive?
    end
  end

  it 'serializes a contact merge and an appointment link across Contact and ContactInbox locks' do
    mergee = create(:contact, account: account)
    contact_inbox
    held = Queue.new
    release = Queue.new
    pause_after_lock(contact_inbox, held, release)
    service = described_class.new(
      account: account, appointment: Scheduling::Appointment.find(appointment.id), inbox: inbox,
      params: { contact_id: contact.id, contact_inbox_id: contact_inbox.id }, actor: creator
    )
    allow(service).to receive(:resolve_contact_inbox).and_return(contact_inbox)

    creator_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { service.perform }
    rescue StandardError => e
      e
    end
    creator_pid = Timeout.timeout(15) { held.pop }
    merge_started = Queue.new
    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        merge_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        ContactMergeAction.new(account: account, base_contact: Contact.find(contact.id), mergee_contact: mergee).perform
      end
    rescue StandardError => e
      e
    end
    merge_pid = Timeout.timeout(15) { merge_started.pop }
    wait_until_blocked!(merge_pid, creator_pid)
    release << true
    creation = Timeout.timeout(15) { creator_thread.value }
    merged = Timeout.timeout(15) { merge_thread.value }
    raise creation if creation.is_a?(StandardError)
    raise merged if merged.is_a?(StandardError)

    expect(appointment.reload).to have_attributes(contact_id: contact.id, conversation_id: creation.conversation_id, owner_id: creator.id)
    expect(merged.id).to eq(contact.id)
    expect(Contact.exists?(mergee.id)).to be false
  ensure
    release&.push(true)
    [creator_thread, merge_thread].compact.each do |thread|
      Timeout.timeout(15) { thread.value } if thread.alive?
    end
  end

  it 'serializes a distinct ContactInbox identity resolution and appointment link without an advisory lock cycle' do
    contact_inbox
    other_identity = create(:contact_inbox, contact: contact, inbox: inbox, source_id: SecureRandom.uuid)
    held = Queue.new
    release = Queue.new
    scheduler_contact = Contact.find(contact.id)
    pause_after_lock(scheduler_contact, held, release)
    allow(account.contacts).to receive(:find).with(contact.id).and_return(scheduler_contact)
    service = described_class.new(
      account: account, appointment: Scheduling::Appointment.find(appointment.id), inbox: inbox,
      params: { contact_id: contact.id, contact_inbox_id: contact_inbox.id }, actor: creator
    )

    creator_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { service.perform }
    rescue StandardError => e
      e
    end
    creator_pid = Timeout.timeout(15) { held.pop }
    resolver_started = Queue.new
    resolver_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        resolver_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        Conversations::IdentityResolver.resolve_primary!(
          contact_inbox: ContactInbox.find(other_identity.id), attributes: { assignee_id: creator.id, status: :open }
        )
      end
    rescue StandardError => e
      e
    end
    resolver_pid = Timeout.timeout(15) { resolver_started.pop }
    wait_until_blocked!(resolver_pid, creator_pid)
    release << true
    creation = Timeout.timeout(15) { creator_thread.value }
    resolved = Timeout.timeout(15) { resolver_thread.value }
    raise creation if creation.is_a?(StandardError)
    raise resolved if resolved.is_a?(StandardError)

    expect(creation.reload.conversation_id).to eq(resolved.id)
    expect(appointment.reload).to have_attributes(conversation_id: resolved.id, owner_id: creator.id)
    expect(Conversation.where(account: account, contact: contact, inbox: inbox, identity_key: 'primary').count).to eq(1)
  ensure
    release&.push(true)
    [creator_thread, resolver_thread].compact.each do |thread|
      Timeout.timeout(15) { thread.value } if thread.alive?
    end
  end
end
