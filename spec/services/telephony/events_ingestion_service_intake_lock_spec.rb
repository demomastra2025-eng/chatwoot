require 'rails_helper'

# The legs of one physical call must take turns: the caller's intake lock goes
# before the call session row, the conversation and its messages.
RSpec.describe Telephony::EventsIngestionService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:call_ref) { 'sipuni:janus:intake-lock-leg-1' }
  let!(:call_session) do
    create(
      :telephony_call_session,
      account: account, conversation: conversation, contact: conversation.contact, inbox: inbox,
      provider: 'sipuni', direction: 'inbound', status: 'ringing', external_call_ref: call_ref
    )
  end
  let(:payload) do
    {
      event_key: 'evt-intake-lock-1', account_id: account.id.to_s, call_ref: call_ref, provider: 'sipuni',
      event: 'session_completed', status: 'completed', direction: 'inbound'
    }
  end

  def statements_of
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') { |*, details| statements << details[:sql] }
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it 'is taken for the caller before the call session row is locked' do
    statements = statements_of { described_class.new(payload: payload).perform }

    intake_lock = statements.index { |sql| sql.include?('pg_advisory_xact_lock') }
    row_lock = statements.index { |sql| sql.include?('FROM "telephony_call_sessions"') && sql.include?('FOR UPDATE') }
    expect(intake_lock).to be_present
    expect(row_lock).to be_present
    expect(intake_lock).to be < row_lock
  end

  it 'is taken for the caller number of the call' do
    allow(Telephony::CallIntakeLock).to receive(:acquire!).and_call_original

    described_class.new(payload: payload).perform

    expect(Telephony::CallIntakeLock).to have_received(:acquire!)
      .with(account_id: account.id, phone_number: call_session.from_number).at_least(:once)
  end

  it 'covers the side effects of the event too, so sibling legs never meet on the conversation rows' do
    open_transactions = []
    allow(Telephony::CallIntakeLock).to receive(:acquire!).and_wrap_original do |original, **args|
      open_transactions << ActiveRecord::Base.connection.transaction_open?
      original.call(**args)
    end

    described_class.new(payload: payload).perform

    expect(open_transactions.size).to be >= 2
    expect(open_transactions).to all(be(true))
  end

  it 'is not taken for an outbound call' do
    call_session.update!(direction: 'outbound')
    allow(Telephony::CallIntakeLock).to receive(:acquire!).and_call_original

    described_class.new(payload: payload.merge(direction: 'outbound')).perform

    expect(Telephony::CallIntakeLock).not_to have_received(:acquire!)
  end
end
