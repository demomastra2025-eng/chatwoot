require 'rails_helper'
require 'timeout'

# M6 against an in-flight touch (sc8rv2 C2b): a number transfer that starts while a touch execution holds the appointment
# and touch locks waits for that delivery, then moves the chat and re-points the settled touch with it, so the touch's
# target contact, conversation and ContactInbox stay consistent. Non-transactional: each thread uses its own connection.
RSpec.describe Reminders::ExecuteService do
  self.use_transactional_tests = false

  around do |example|
    with_modified_env('EVOLUTION_API_URL' => 'https://evolution.example.com', 'EVOLUTION_API_KEY' => 'test-api-key',
                      'FRONTEND_URL' => 'https://app.example.com') { example.run }
  end

  # One TRUNCATE ... CASCADE over every table: unlike truncate_tables it never disables triggers, so an interrupted run
  # cannot leave the display-id and foreign-key triggers of the test database switched off.
  after do
    connection = ActiveRecord::Base.connection
    tables = (connection.tables - %w[schema_migrations ar_internal_metadata]).map { |table| connection.quote_table_name(table) }
    connection.execute("TRUNCATE TABLE #{tables.join(', ')} CASCADE")
  end

  let(:account) do
    create(:account, locale: 'ru', limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('scheduling') }
  end
  let(:phone) { SharedPhoneHelpers::FAMILY_PHONE }
  let(:mother) { create(:contact, account: account, name: 'Mother', phone_number: '+77000000008') }

  before do
    stub_request(:any, /.*/).to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
    # The transfer with history transfer switched on (it ships off, see Contacts::SharedPhoneSwitches).
    enable_shared_phone_switches!
  end

  def in_thread
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        yield
      rescue StandardError => e
        e
      end
    end
  end

  def deadlocks
    connection = ActiveRecord::Base.connection
    connection.execute('SELECT pg_stat_clear_snapshot()')
    connection.select_value('SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()').to_i
  end

  def family_touch
    inbox = create(:channel_whatsapp_web, account: account).inbox
    _contact_inbox, conversation = shared_phone_chat(account, mother, inbox, phone.delete('+'))
    card = shared_phone_card(account, mother)
    appointment = create(:scheduling_appointment, account: account, contact: mother, conversation: conversation, patient_contact: card,
                                                  client_first_name: 'Son', client_last_name: 'Patient', client_middle_name: nil,
                                                  client_name: 'Son Patient', client_phone: phone, client_identifier: nil,
                                                  starts_at: 2.days.from_now, ends_at: 2.days.from_now + 30.minutes)
    touch = create(:reminder, account: account, touch_conversation: conversation, conversation: conversation, remindable: appointment,
                              status: :processing, body: 'Son visit', scheduled_at: 1.minute.ago)
    [conversation, card, touch]
  end

  it 'C6 a delivery that records its ContactInbox while a transfer holds that ContactInbox does not deadlock', :aggregate_failures do
    conversation, card, touch = family_touch
    touch.update_columns(target_contact_inbox_id: nil) # rubocop:disable Rails/SkipsModelValidations
    before = deadlocks
    delivering = Queue.new
    allow_any_instance_of(Reminders::MessageMaterializer).to receive(:perform).and_wrap_original do |original, *args, **kwargs| # rubocop:disable RSpec/AnyInstance
      delivering << true
      sleep 2
      original.call(*args, **kwargs)
    end

    executor = in_thread { described_class.new(reminder: Reminder.find(touch.id)).perform }
    promoter = in_thread do
      Timeout.timeout(20) { delivering.pop }
      Contacts::SharedPhonePromotionService.new(card: Contact.find(card.id), basis: 'medelement').perform
    end
    results = [executor, promoter].map { |thread| Timeout.timeout(60) { thread.value } }

    expect(results).to all(satisfy { |value| !value.is_a?(Exception) })
    expect(deadlocks - before).to eq(0)
    expect(Reminder.find(touch.id)).to have_attributes(status: 'completed', target_contact_id: card.id, target_conversation_id: conversation.id)
    messages = Message.outgoing.where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s)
    expect(messages.count).to eq(1)
    expect(messages.first.conversation.reload.contact_id).to eq(card.id)
  end

  it 'C2b a transfer during the delivery waits for it and keeps the touch consistent with its chat', :aggregate_failures do
    conversation, card, touch = family_touch
    delivering = Queue.new
    allow_any_instance_of(Reminders::MessageMaterializer).to receive(:perform).and_wrap_original do |original, *args, **kwargs| # rubocop:disable RSpec/AnyInstance
      delivering << true
      sleep 1.5
      original.call(*args, **kwargs)
    end

    executor = in_thread { described_class.new(reminder: Reminder.find(touch.id)).perform }
    promoter = in_thread do
      Timeout.timeout(20) { delivering.pop }
      Contacts::SharedPhonePromotionService.new(card: Contact.find(card.id), basis: 'medelement').perform
    end
    results = [executor, promoter].map { |thread| Timeout.timeout(60) { thread.value } }

    expect(results).to all(satisfy { |value| !value.is_a?(Exception) })
    expect(conversation.reload.contact_id).to eq(card.id)
    stored = Reminder.find(touch.id)
    expect(stored).to have_attributes(status: 'completed', target_contact_id: card.id, target_conversation_id: conversation.id,
                                      conversation_id: conversation.id)
    expect(ContactInbox.find(stored.target_contact_inbox_id).contact_id).to eq(card.id)
    expect(stored).to be_valid
    expect(Message.outgoing.where("additional_attributes ->> 'touch_id' = ?", touch.id.to_s).count).to eq(1)
  end
end
