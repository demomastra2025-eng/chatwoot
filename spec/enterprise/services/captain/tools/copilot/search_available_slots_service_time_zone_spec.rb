require 'rails_helper'

# A date or a time without an offset that the model passes to the scheduling reads is the clinic time that the Now block of the
# prompt states (the zone of the inbox, else the reporting zone of the account), not the UTC of the server. A value with an offset
# keeps it. All data is synthetic.
RSpec.describe Captain::Tools::Copilot::SearchAvailableSlotsService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:inbox_zone) { 'Asia/Almaty' }
  let(:inbox) { create(:inbox, account: account, timezone: inbox_zone) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:tool) { described_class.new(assistant, user: user, conversation: conversation) }
  let(:resource) { create(:scheduling_resource, account: account, name: 'Aigerim', timezone: 'Asia/Almaty', slot_duration_min: 30) }

  before do
    account.enable_features!('scheduling')
    # 2026-04-20 is a Monday.
    create(:scheduling_work_rule, resource: resource, weekday: 1, start_minute: 9 * 60, end_minute: 18 * 60)
  end

  def search(searcher = tool, **arguments)
    JSON.parse(searcher.execute(resource_ids: [resource.id], limit: 1, **arguments))
  end

  it 'reads a time without an offset as the clinic time of the inbox' do
    payload = search(from: '2026-04-20T09:00', to: '2026-04-20T10:00')

    expect(payload['range']).to eq('from' => '2026-04-20T09:00:00+05:00', 'to' => '2026-04-20T10:00:00+05:00')
    expect(payload['slots'].pluck('starts_at')).to eq(['2026-04-20T09:00:00+05:00'])
  end

  it 'reads a date without a time as the start of that day in the clinic zone' do
    payload = search(from: '2026-04-20', to: '2026-04-21')

    expect(payload['range']).to eq('from' => '2026-04-20T00:00:00+05:00', 'to' => '2026-04-21T00:00:00+05:00')
  end

  context 'when the inbox has another zone' do
    let(:inbox_zone) { 'Europe/Moscow' }

    it 'reads the time in that zone' do
      payload = search(from: '2026-04-20T09:00', to: '2026-04-20T12:00')

      expect(payload['range']).to eq('from' => '2026-04-20T09:00:00+03:00', 'to' => '2026-04-20T12:00:00+03:00')
      expect(payload['slots'].pluck('starts_at')).to eq(['2026-04-20T11:00:00+05:00'])
    end

    it 'keeps an offset that the model wrote' do
      payload = search(from: '2026-04-20T09:00:00+05:00', to: '2026-04-20T10:00:00+05:00')

      expect(Time.zone.parse(payload['range']['from'])).to eq(Time.utc(2026, 4, 20, 4))
      expect(payload['slots'].pluck('starts_at')).to eq(['2026-04-20T09:00:00+05:00'])
    end
  end

  context 'without a conversation, as in Copilot' do
    it 'reads the time in the reporting zone of the account' do
      account.update!(reporting_timezone: 'Asia/Bishkek')

      payload = search(described_class.new(assistant, user: user), from: '2026-04-20T09:00', to: '2026-04-20T12:00')

      expect(payload['range']).to eq('from' => '2026-04-20T09:00:00+06:00', 'to' => '2026-04-20T12:00:00+06:00')
    end

    it 'falls back to the workspace zone when the account has none' do
      payload = search(described_class.new(assistant, user: user), from: '2026-04-20T09:00', to: '2026-04-20T12:00')

      expect(payload['range']).to eq('from' => '2026-04-20T09:00:00+05:00', 'to' => '2026-04-20T12:00:00+05:00')
    end
  end
end
