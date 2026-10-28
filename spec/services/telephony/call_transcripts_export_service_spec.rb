require 'rails_helper'

RSpec.describe Telephony::CallTranscriptsExportService do
  let(:account) { create(:account) }
  let(:call) do
    create(:telephony_call_session, account: account, started_at: Time.zone.parse('2026-10-20 12:00'),
                                    metadata: { 'recording' => { 'transcription' => {
                                      'channels' => 2, 'summary' => 'Пациент записался.', 'outcome' => 'booked',
                                      'topics' => ['запись'], 'transcript_items' => [
                                        { 'speaker' => 'operator', 'speaker_label' => 'Сотрудник',
                                          'timestamp' => '00:02', 'text' => 'Добрый день' }
                                      ]
                                    } } })
  end

  it 'exports structured dialogue, outcome and filters the period' do
    call
    service = described_class.new(relation: account.telephony_call_sessions,
                                  since: '2026-10-20', until_at: '2026-10-21')

    expect(service.rows.first).to include('outcome' => 'booked', 'channels' => 2,
                                          'transcript' => '[00:02] Сотрудник: Добрый день')
    expect(CSV.parse(service.csv).first).to include('summary', 'topics', 'transcript')
    expect(described_class.new(relation: account.telephony_call_sessions,
                               since: '2026-10-22', until_at: '2026-10-23').rows).to be_empty
  end
end
