require 'rails_helper'
require 'timeout'

# These examples exercise both provider services against the same conversation/appointment lock graph.
RSpec.describe 'provider contact merge lock ordering' do # rubocop:disable RSpec/DescribeClass
  self.use_transactional_tests = false
  let(:merge_phone) { '+15551234567' }

  let(:account) { create(:account) }
  let(:channel) do
    if RSpec.current_example.metadata[:provider] == :telegram
      create(:channel_telegram_personal, account: account, phone_number: '+77066318623')
    elsif RSpec.current_example.metadata[:provider] == :cloud
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    else
      create(:channel_whatsapp_web, account: account)
    end
  end
  let(:inbox) { channel.inbox }
  let(:source_contact) { create(:contact, account: account, identifier: 'telegram_personal:23') }
  let(:target_contact) { create(:contact, account: account, phone_number: merge_phone) }
  let(:contact_inbox) { create(:contact_inbox, contact: source_contact, inbox: inbox) }

  after do
    Scheduling::Appointment.where(account_id: account.id).find_each(&:destroy!)
    Conversation.where(account_id: account.id).find_each(&:destroy!)
    AutomationEvent.where(account_id: account.id).delete_all
    ContactChannelProfile.where(account_id: account.id).delete_all
    ContactInbox.where(inbox_id: inbox.id).delete_all
    Inbox.where(id: inbox.id).delete_all
    channel.class.where(id: channel.id).delete_all
    Scheduling::Resource.where(account_id: account.id).delete_all
    Scheduling::Service.where(account_id: account.id).delete_all
    Contact.where(account_id: account.id).delete_all
    Account.where(id: account.id).delete_all
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

  def pause_after_contact_inbox_transfer(source, held, release)
    association = source.contact_inboxes
    source.define_singleton_method(:contact_inboxes) { association }
    association.define_singleton_method(:update_all) do |*args|
      super(*args).tap do
        held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        release.pop
      end
    end
  end

  def pause_after_contact_lock(contact, held, release)
    paused = false
    contact.define_singleton_method(:lock!) do |*args, **kwargs|
      super(*args, **kwargs).tap do
        unless paused
          paused = true
          held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          release.pop
        end
      end
    end
  end

  def provider_merge(provider, source)
    if provider == :telegram
      service = TelegramPersonal::ContactSyncService.new(
        inbox: inbox, params: { peer_user_id: '23', phone_number: '15551234567' }
      )
      service.instance_variable_set(:@contact, source)
      service.send(:merge_phone_contact!)
    else
      service = WhatsappWeb::ContactSyncService.new(
        channel: channel,
        contact_payload: { remoteJid: '15551234567@s.whatsapp.net' }
      )
      service.send(:merge_phone_contact!, source_contact: source, phone_number: merge_phone)
    end
  end

  # Two connections must overlap inside real PostgreSQL locks, not only Ruby threads.
  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength
  def race_phone_update_with_merge(target)
    held = Queue.new
    release = Queue.new
    phone_started = Queue.new
    merge_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { yield held, release }
    rescue StandardError => e
      e
    end
    merger_pid = Timeout.timeout(15) { held.pop }
    phone_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        phone_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        Contact.find(target.id).update!(phone_number: '+15550000001')
      end
    rescue StandardError => e
      e
    end
    phone_pid = Timeout.timeout(15) { phone_started.pop }
    wait_until_blocked!(phone_pid, merger_pid)
    expect(ActiveRecord::Base.connection.select_value("SELECT wait_event FROM pg_stat_activity WHERE pid = #{phone_pid}")).to eq('advisory')
    release << true
    merged = Timeout.timeout(15) { merge_thread.value }
    updated = Timeout.timeout(15) { phone_thread.value }
    raise merged if merged.is_a?(StandardError)
    raise updated if updated.is_a?(StandardError)

    expect(target.reload.phone_number).to eq('+15550000001')
  ensure
    release&.push(true)
    [merge_thread, phone_thread].compact.each do |thread|
      Timeout.timeout(15) { thread.value } if thread.alive?
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength

  %i[telegram whatsapp].each do |provider|
    it "serializes #{provider} contact transfer before stale ContactInbox identity resolution", provider: provider do
      contact_inbox
      target_contact
      source = Contact.find(source_contact.id)
      held = Queue.new
      release = Queue.new
      pause_after_contact_inbox_transfer(source, held, release)
      merge_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { provider_merge(provider, source) }
      rescue StandardError => e
        e
      end
      merger_pid = Timeout.timeout(15) { held.pop }
      resolver_started = Queue.new
      resolver_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          resolver_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          Conversations::IdentityResolver.resolve_primary!(
            contact_inbox: ContactInbox.find(contact_inbox.id), attributes: { status: :open }
          )
        end
      rescue StandardError => e
        e
      end
      resolver_pid = Timeout.timeout(15) { resolver_started.pop }
      wait_until_blocked!(resolver_pid, merger_pid)
      release << true
      merged = Timeout.timeout(15) { merge_thread.value }
      resolved = Timeout.timeout(15) { resolver_thread.value }
      raise merged if merged.is_a?(StandardError)
      raise resolved if resolved.is_a?(StandardError)

      expect(contact_inbox.reload.contact_id).to eq(target_contact.id)
      expect(resolved.reload.contact_id).to eq(target_contact.id)
      expect(target_contact.reload.identifier).to eq(source_contact.identifier)
      expect(Conversation.where(account: account, contact_id: target_contact.id, identity_key: 'primary').count).to eq(1)
      expect(Contact.exists?(source_contact.id)).to be false
    ensure
      release&.push(true)
      [merge_thread, resolver_thread].compact.each do |thread|
        Timeout.timeout(15) { thread.value } if thread.alive?
      end
    end

    it "serializes #{provider} contact transfer after an appointment conversation link", provider: provider do
      contact_inbox
      target_contact
      appointment = create(:scheduling_appointment, account: account, contact: source_contact)
      actor = create(:user, account: account, role: :agent)
      scheduled_contact = Contact.find(source_contact.id)
      held = Queue.new
      release = Queue.new
      pause_after_contact_lock(scheduled_contact, held, release)
      allow(account.contacts).to receive(:find).with(source_contact.id).and_return(scheduled_contact)
      service = Scheduling::Appointments::CreateConversationService.new(
        account: account, appointment: Scheduling::Appointment.find(appointment.id), inbox: inbox,
        params: { contact_id: source_contact.id, contact_inbox_id: contact_inbox.id }, actor: actor
      )
      creator_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { service.perform }
      rescue StandardError => e
        e
      end
      creator_pid = Timeout.timeout(15) { held.pop }
      merger_started = Queue.new
      merge_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          merger_started << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          provider_merge(provider, Contact.find(source_contact.id))
        end
      rescue StandardError => e
        e
      end
      merger_pid = Timeout.timeout(15) { merger_started.pop }
      wait_until_blocked!(merger_pid, creator_pid)
      release << true
      creation = Timeout.timeout(15) { creator_thread.value }
      merged = Timeout.timeout(15) { merge_thread.value }
      raise creation if creation.is_a?(StandardError)
      raise merged if merged.is_a?(StandardError)

      expect(appointment.reload).to have_attributes(contact_id: target_contact.id, conversation_id: creation.conversation_id)
      expect(Conversation.find(creation.conversation_id).contact_id).to eq(target_contact.id)
      expect(contact_inbox.reload.contact_id).to eq(target_contact.id)
      expect(Contact.exists?(source_contact.id)).to be false
    ensure
      release&.push(true)
      [creator_thread, merge_thread].compact.each do |thread|
        Timeout.timeout(15) { thread.value } if thread.alive?
      end
    end
  end

  it 'transfers a WhatsApp identifier collision through the shared lock path', provider: :whatsapp do
    source_contact.update!(identifier: 'whatsapp_web:143907392331785@lid')
    contact_inbox
    target_contact
    service = WhatsappWeb::ContactSyncService.new(
      channel: channel,
      contact_payload: { remoteJid: '15551234567@s.whatsapp.net', remoteLid: '143907392331785@lid' }
    )

    service.send(:merge_identifier_contact!, target_contact: target_contact)

    expect(contact_inbox.reload.contact_id).to eq(target_contact.id)
    expect(target_contact.reload).to be_persisted
    expect(Contact.exists?(source_contact.id)).to be false
  end

  it 'transfers a WhatsApp identifier and phone without leaving a duplicate identity', provider: :whatsapp do
    target_contact.update!(phone_number: nil)
    source_contact.update!(identifier: 'whatsapp_web:143907392331785@lid', phone_number: merge_phone)
    contact_inbox
    service = WhatsappWeb::ContactSyncService.new(
      channel: channel,
      contact_payload: { remoteJid: '15551234567@s.whatsapp.net', remoteLid: '143907392331785@lid' }
    )

    service.send(:merge_identifier_contact!, target_contact: target_contact)

    expect(target_contact.reload).to have_attributes(identifier: source_contact.identifier, phone_number: merge_phone)
    expect(account.contacts.where(phone_number: merge_phone).pluck(:id)).to eq([target_contact.id])
    expect(contact_inbox.reload.contact_id).to eq(target_contact.id)
    expect(Contact.exists?(source_contact.id)).to be false
  end

  it 'does not invert phone advisory and Contact locks on a WhatsApp identifier collision', provider: :whatsapp do
    target_contact.update!(phone_number: nil)
    source_contact.update!(identifier: 'whatsapp_web:143907392331785@lid', phone_number: merge_phone)
    contact_inbox
    service = WhatsappWeb::ContactSyncService.new(
      channel: channel,
      contact_payload: { remoteJid: '15551234567@s.whatsapp.net', remoteLid: '143907392331785@lid' }
    )
    target = Contact.find(target_contact.id)
    race_phone_update_with_merge(target) do |held, release|
      original_reload = target.method(:reload)
      target.define_singleton_method(:reload) do |*args, **kwargs|
        original_reload.call(*args, **kwargs).tap do
          next unless kwargs[:lock]

          held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
          release.pop
        end
      end
      service.send(:merge_identifier_contact!, target_contact: target)
    end
    expect(contact_inbox.reload.contact_id).to eq(target.id)
    expect(target.reload.identifier).to eq(source_contact.identifier)
    expect(account.contacts.where(phone_number: merge_phone).count).to eq(0)
    expect(Contact.exists?(source_contact.id)).to be false
  end

  it 'does not invert phone advisory and Contact locks on a manual merge' do
    base = create(:contact, account: account, phone_number: nil)
    mergee = create(:contact, account: account, phone_number: merge_phone)
    action = ContactMergeAction.new(account: account, base_contact: base, mergee_contact: mergee)
    race_phone_update_with_merge(base) do |held, release|
      allow(action).to receive(:lock_contact_inboxes).and_wrap_original do |original|
        original.call
        held << ActiveRecord::Base.connection.select_value('SELECT pg_backend_pid()').to_i
        release.pop
      end
      action.perform
    end
    expect(Contact.exists?(mergee.id)).to be false
  end

  it 'backfills a WhatsApp Cloud phone before creating its second ContactInbox', provider: :cloud do
    source_contact.update!(phone_number: nil)
    contact_inbox
    service = Whatsapp::IdentifierSyncService.new(contact_inbox: contact_inbox, contact: Contact.find(source_contact.id))
    allow(service).to receive(:create_contact_inboxes).and_wrap_original do |original, *args|
      expect(source_contact.reload.phone_number).to eq(merge_phone)
      original.call(*args)
    end
    service.perform(source_ids: ['77001234567'], phone_number: merge_phone)

    expect(source_contact.reload.phone_number).to eq(merge_phone)
    expect(inbox.contact_inboxes.find_by!(source_id: '77001234567').contact_id).to eq(source_contact.id)
  end
end
