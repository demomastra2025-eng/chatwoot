require 'rails_helper'

RSpec.describe Telephony::ExternalRecordingCacheJob do
  let(:account) { create(:account) }
  let(:external_url) { 'https://sipuni.com/api/crm/record?id=1790593304.1311701&hash=recording-signature&user=015856' }

  def call_session_with(status:, answered_at: nil)
    create(
      :telephony_call_session,
      account: account,
      provider: 'sipuni',
      status: status,
      answered_at: answered_at,
      recording_ref: external_url,
      metadata: { 'recording' => { 'recording_ref' => external_url, 'recording_url' => external_url } }
    )
  end

  it 'skips calls nobody answered without contacting the provider' do
    call_session = call_session_with(status: 'missed')

    expect(Telephony::ExternalRecordingCacheService).not_to receive(:cache!)

    described_class.perform_now(call_session.id)
  end

  it 'caches recordings for answered calls' do
    call_session = call_session_with(status: 'completed', answered_at: 1.minute.ago)

    expect(Telephony::ExternalRecordingCacheService).to receive(:cache!).with(call_session: call_session)

    described_class.perform_now(call_session.id)
  end
end
