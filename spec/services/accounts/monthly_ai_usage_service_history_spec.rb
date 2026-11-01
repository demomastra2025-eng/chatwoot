require 'rails_helper'
require 'benchmark'

RSpec.describe Accounts::MonthlyAiUsageService do
  it 'uses indexed contact history for 1000 replies and absorbs late feedback without displacing the current window' do
    account = create(:account)
    contact = create(:contact, account: account)
    other = create(:contact, account: account)
    foreign = create(:contact)
    conversation = create(:conversation, account: account, contact: contact)
    first = Time.utc(2026, 6, 1, 8)
    rows = Array.new(1000) do |idx|
      { account_id: account.id, contact_id: contact.id, event_key: "message:benchmark-#{idx}",
        bucket: described_class::AI_DIALOGS_MONTHLY_KEY, occurred_at: first + (idx / 10).days + (idx % 10).minutes, quantity: 1 }
    end
    [other, foreign].each do |person|
      10_000.times do |idx|
        rows << { account_id: person.account_id, contact_id: person.id, event_key: "message:other-#{person.id}-#{idx}",
                  bucket: described_class::AI_DIALOGS_MONTHLY_KEY, occurred_at: first + idx.seconds, quantity: 1 }
      end
    end
    Accounts::AiUsageEvent.insert_all!(rows) # rubocop:disable Rails/SkipsModelValidations
    window = Accounts::AiDialogWindow.new(contact, at: first)
    window.import_legacy_events!
    window.record_reply!
    state = Accounts::AiDialogState.find_by!(contact_id: contact.id)
    account.update!(custom_attributes: { described_class::AI_DIALOGS_MONTHLY_KEY => state.state['period_counts'] })
    service = described_class.new(account)
    result = nil
    late_ms = Benchmark.realtime { result = service.record_ai_dialog_reply!(conversation, message_id: 'late', at: first + 30.seconds) } * 1000
    expect(result).to eq(:existing_dialog)
    current_ms = Benchmark.realtime do
      service.record_ai_dialog_reply!(conversation, message_id: 'current', at: first + 99.days + 11.minutes)
    end * 1000
    expect(account.reload.custom_attributes[described_class::AI_DIALOGS_MONTHLY_KEY].values.sum).to eq(100)
    expect(state.reload.state['windows'].size).to eq(100)
    expect(Time.iso8601(state.state['started_at'])).to eq(first + 99.days)
    scope = Accounts::AiUsageEvent.where(account_id: account.id, contact_id: contact.id, bucket: described_class::AI_DIALOGS_MONTHLY_KEY)
                                  .where('quantity > 0').order(:occurred_at, :id).select(:occurred_at)
    connection = ActiveRecord::Base.connection
    connection.execute('ANALYZE account_ai_usage_events')
    plan = connection.select_value("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) #{scope.to_sql}")
    expect(plan.to_s).to include('idx_ai_usage_events_contact_time')
    expect(scope.count).to eq(1002)
    puts "METERING_BENCHMARK history=1000 unrelated=20000 late_ms=#{late_ms.round(2)} " \
         "current_ms=#{current_ms.round(2)} index=idx_ai_usage_events_contact_time"
  end
end
