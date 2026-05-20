require 'rails_helper'

RSpec.describe Whatsapp::CallCleanupJob do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:provider) { double('provider', reject_call: true, terminate_call: true) }
  let(:media_client) { instance_double(Whatsapp::MediaServerClient) }
  let(:call) do
    create(
      :call,
      account: account,
      direction: :incoming,
      status: 'ringing',
      media_session_id: 'media-stale-1',
      created_at: 61.seconds.ago
    )
  end

  before do
    Current.suppress_runtime_events = true
    allow_any_instance_of(Channel::Whatsapp).to receive(:provider_service).and_return(provider)
    allow(Whatsapp::MediaServerClient).to receive(:new).and_return(media_client)
    allow(media_client).to receive(:terminate_session)
    allow(Whatsapp::CallMessageBuilder).to receive(:update_status!)
    allow(ActionCable.server).to receive(:broadcast)
  end

  after do
    Current.suppress_runtime_events = nil
  end

  it 'runs on the isolated WhatsApp calls queue' do
    expect(described_class.queue_name).to eq('whatsapp_calls')
  end

  it 'expires one stale inbound ringing call after the 60 second answer window' do
    described_class.perform_now(call.id)

    expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'timeout')
    expect(media_client).to have_received(:terminate_session).with('media-stale-1')
    expect(provider).to have_received(:reject_call).with(call.provider_call_id)
    expect(Whatsapp::CallMessageBuilder).to have_received(:update_status!).with(call: call, status: 'no_answer')
    expect(ActionCable.server).to have_received(:broadcast).with(
      "account_#{account.id}",
      hash_including(event: 'whatsapp_call.ended', data: hash_including(call_id: call.provider_call_id, status: 'no_answer'))
    )
  end

  it 'expires one stale outbound ringing call and terminates the provider/media sessions' do
    call.update!(direction: :outgoing, accepted_by_agent: agent)

    described_class.perform_now(call.id)

    expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'timeout')
    expect(media_client).to have_received(:terminate_session).with('media-stale-1')
    expect(provider).to have_received(:terminate_call).with(call.provider_call_id)
  end

  it 'expires a stale prepared outbound call without calling the provider for a fake pending id' do
    call.update!(
      direction: :outgoing,
      accepted_by_agent: agent,
      provider_call_id: 'pending_outbound_test',
      meta: { 'outbound_prepare_pending' => true }
    )

    described_class.perform_now(call.id)

    expect(call.reload).to have_attributes(status: 'no_answer', end_reason: 'timeout')
    expect(media_client).to have_received(:terminate_session).with('media-stale-1')
    expect(provider).not_to have_received(:terminate_call)
  end

  it 'does not expire a fresh ringing call before the timeout' do
    call.update!(created_at: 30.seconds.ago)

    described_class.perform_now(call.id)

    expect(call.reload.status).to eq('ringing')
    expect(media_client).not_to have_received(:terminate_session)
    expect(provider).not_to have_received(:reject_call)
    expect(provider).not_to have_received(:terminate_call)
  end

  it 'does not expire an inbound ringing call reserved by an accepting agent' do
    call.update!(accepted_by_agent: agent)

    described_class.perform_now(call.id)

    expect(call.reload.status).to eq('ringing')
    expect(media_client).not_to have_received(:terminate_session)
    expect(provider).not_to have_received(:reject_call)
    expect(provider).not_to have_received(:terminate_call)
  end
end
