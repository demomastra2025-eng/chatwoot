require 'rails_helper'

RSpec.describe Meta::AuthorizationErrorHandler do
  let(:channel) { instance_double(Channel::FacebookPage) }
  let(:health_recorder) { instance_double(Meta::ChannelCredentialHealthRecorder, record_result!: true) }

  before do
    allow(channel).to receive(:authorization_error!)
    allow(channel).to receive(:prompt_reauthorization!)
    allow(Meta::ChannelCredentialHealthRecorder).to receive(:new).with(channel).and_return(health_recorder)
  end

  it 'prompts immediately for a confirmed permanent token invalidation' do
    described_class.handle(
      channel: channel,
      payload: { error: { code: 190, error_subcode: 460, message: 'Session invalidated' } }
    )

    expect(channel).to have_received(:prompt_reauthorization!).once
    expect(channel).not_to have_received(:authorization_error!)
    expect(health_recorder).to have_received(:record_result!).with(
      an_object_having_attributes(status: :action_required, reason: 'provider_authorization_failed')
    ).once
  end

  it 'routes ambiguous token failures through the threshold and health-confirmation path' do
    described_class.handle(
      channel: channel,
      payload: { error: { code: 190, message: 'Error validating access token' } }
    )

    expect(channel).to have_received(:authorization_error!).once
    expect(channel).not_to have_received(:prompt_reauthorization!)
  end

  it 'does not mutate reauthorization state for transient provider failures' do
    result = described_class.handle(channel: channel, payload: { error: { code: 4, message: 'Rate limited' } })

    expect(result).to be_transient
    expect(channel).not_to have_received(:authorization_error!)
    expect(channel).not_to have_received(:prompt_reauthorization!)
  end
end
