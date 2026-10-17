# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Beeline::CallHistorySyncService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:connection) do
    create(:telephony_provider_connection, account: account, provider_kind: 'beeline', status: 'active')
  end
  let(:voice_channel) do
    Channel::Voice.create!(
      account: account,
      provider: 'beeline',
      phone_number: '+77761234567',
      provider_config: {
        'provider_kind' => 'beeline',
        'number_ref' => 'num-beeline-sync-1',
        'provider_connection_id' => connection.id,
        'routing_mode' => 'operator',
        'display_phone_number' => '+77761234567',
        'ingress_number' => '+77761234567',
        'beeline_events_webhook_token' => 'webhook-tok-999',
        'beeline_api_token' => 'mpbx-api-token-secret'
      }
    )
  end
  let!(:inbox) do
    create(:inbox, account: account, channel: voice_channel, name: 'Beeline Sync Inbox')
  end
  let!(:number_binding) do
    Telephony::NumberBinding.sync_from_voice_channel!(voice_channel.reload)
  end
  let!(:sip_profile) do
    create(
      :telephony_sip_profile,
      account: account,
      inbox: inbox,
      provider_connection: connection,
      user: user,
      profile_kind: 'human_operator',
      internal_extension: '201',
      sip_username: 'SIP_201@vpbx-company.cloudpbx.beeline.kz',
      enabled: true,
      status: 'active'
    )
  end

  let(:api_client) { instance_double(Telephony::Beeline::ApiClient, configured?: true) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('FRONTEND_URL', '').and_return('https://dev.one-link.kz')
  end

  it 'subscribes webhook, syncs offline missed calls and answered calls with recordings, and skips already synced records' do
    call_start = 10.minutes.ago.change(usec: 0)
    records = [
      {
        'id' => 'stat-missed-101',
        'direction' => 'INBOUND',
        'status' => 'MISSED',
        'phone' => '87015556677',
        'startDate' => (call_start.to_f * 1000).to_i,
        'duration' => 0,
        'abonent' => {
          'userId' => 'SIP_201@vpbx-company.cloudpbx.beeline.kz',
          'extension' => '201',
          'firstName' => 'Алия',
          'lastName' => 'Оператор'
        }
      },
      {
        'id' => 'stat-answered-102',
        'direction' => 'INBOUND',
        'status' => 'RECEIVED',
        'phone' => '+77023334455',
        'startDate' => ((call_start + 2.minutes).to_f * 1000).to_i,
        'duration' => 35_000,
        'recordId' => 'rec-beeline-555',
        'abonent' => {
          'userId' => 'SIP_201@vpbx-company.cloudpbx.beeline.kz',
          'extension' => '201'
        }
      }
    ]

    initial_vpbx_version = Telephony::VirtualPbx::ConfigBuilder.new(account: account).for_inbox(inbox.reload)[:configuration_version]

    expect(api_client).to receive(:subscribe_webhook).with(
      url: 'https://dev.one-link.kz/beeline/events/webhook-tok-999',
      expires: 86_400,
      subscription_type: 'BASIC_CALL'
    ).and_return({ 'subscriptionId' => 'sub-beeline-1', 'expires' => 86_400 })

    expect(api_client).to receive(:statistics).twice.and_return(records)
    expect(api_client).to receive(:download_recording).with('rec-beeline-555').once.and_return({
      body: 'FAKE_MP3_AUDIO_BYTES',
      content_type: 'audio/mpeg',
      filename: 'beeline-rec-beeline-555.mp3'
    })

    result = described_class.new(
      channel: voice_channel,
      api_client: api_client,
      subscribe_webhook: true
    ).perform

    expect(result).to include(ok: true, synced: 2, skipped: 0, total: 2)
    expect(voice_channel.reload.provider_config_hash['beeline_subscription_id']).to eq('sub-beeline-1')
    expect(Telephony::VirtualPbx::ConfigBuilder.new(account: account.reload).for_inbox(inbox.reload)[:configuration_version]).to eq(initial_vpbx_version)

    missed_session = account.telephony_call_sessions.find_by(external_call_ref: 'beeline:cdr:stat-missed-101')
    expect(missed_session).to be_present
    expect(missed_session.status).to eq('missed')
    expect(missed_session.direction).to eq('inbound')
    expect(missed_session.from_number).to eq('+77015556677')
    expect(missed_session.conversation).to be_present
    expect(missed_session.conversation.reload.additional_attributes['waiting_for_callback']).to eq(true)

    missed_msg = missed_session.conversation.messages.voice_calls.last
    expect(missed_msg).to be_present
    expect(missed_msg.content_attributes.dig('data', 'status')).to eq('missed')
    expect(missed_msg.content_attributes.dig('data', 'waiting_for_callback')).to eq(true)

    answered_session = account.telephony_call_sessions.find_by(external_call_ref: 'beeline:cdr:stat-answered-102')
    expect(answered_session).to be_present
    expect(answered_session.status).to eq('completed')
    expect(answered_session.duration_seconds).to eq(35)
    expect(answered_session.answered_by).to eq("user:#{user.id}")
    expect(answered_session.recording_ref).to start_with("voice-recordings/beeline/#{account.id}/")

    # Second run skips already synced terminal records without creating duplicates
    second_result = described_class.new(
      channel: voice_channel.reload,
      api_client: api_client,
      subscribe_webhook: false
    ).perform

    expect(second_result).to include(ok: true, synced: 0, skipped: 2, total: 2)
    expect(number_binding.reload.metadata).not_to have_key('beeline_api_token')
  end

  it 'correlates /v2/statistics records with existing Xsi-Events webhook sessions without creating duplicate CallSessions' do
    call_start = 5.minutes.ago.change(usec: 0)
    webhook_missed = account.telephony_call_sessions.create!(
      inbox: inbox,
      number_binding: number_binding,
      provider: 'beeline',
      direction: 'inbound',
      status: 'missed',
      external_call_ref: 'beeline:track-webhook-missed-1',
      provider_call_sid: 'track-webhook-missed-1',
      from_number: '+77019998877',
      to_number: '+77761234567',
      started_at: call_start,
      ended_at: call_start + 20.seconds,
      metadata: { 'beeline_ext_tracking_id' => 'track-webhook-missed-1' }
    )
    webhook_answered = account.telephony_call_sessions.create!(
      inbox: inbox,
      number_binding: number_binding,
      provider: 'beeline',
      direction: 'inbound',
      status: 'completed',
      external_call_ref: 'beeline:track-webhook-ans-2',
      provider_call_sid: 'track-webhook-ans-2',
      from_number: '+77021112233',
      to_number: '+77761234567',
      started_at: call_start + 1.minute,
      answered_at: call_start + 65.seconds,
      ended_at: call_start + 95.seconds,
      duration_seconds: 30,
      metadata: { 'beeline_ext_tracking_id' => 'track-webhook-ans-2' }
    )

    records = [
      {
        'id' => 'stat-portal-881',
        'direction' => 'INBOUND',
        'status' => 'MISSED',
        'phone' => '87019998877',
        'startDate' => ((call_start + 2.seconds).to_f * 1000).to_i,
        'duration' => 0
      },
      {
        'id' => 'stat-portal-882',
        'direction' => 'INBOUND',
        'status' => 'RECEIVED',
        'phone' => '87021112233',
        'startDate' => ((call_start + 61.seconds).to_f * 1000).to_i,
        'duration' => 30_000,
        'recordId' => 'rec-late-882'
      }
    ]

    expect(api_client).to receive(:statistics).once.and_return(records)
    expect(api_client).to receive(:download_recording).with('rec-late-882').once.and_return({
      body: 'LATE_RECORDING_MP3',
      content_type: 'audio/mpeg',
      filename: 'beeline-rec-late-882.mp3'
    })

    expect do
      res = described_class.new(
        channel: voice_channel,
        api_client: api_client,
        subscribe_webhook: false
      ).perform
      expect(res).to include(ok: true, synced: 1, skipped: 1, total: 2)
    end.not_to change(Telephony::CallSession, :count)

    expect(webhook_missed.reload.status).to eq('missed')
    expect(webhook_answered.reload.recording_ref).to start_with("voice-recordings/beeline/#{account.id}/")
  end

  it 'renews an existing subscription via PUT /subscription when near expiry' do
    voice_channel.update!(
      provider_config: voice_channel.provider_config_hash.merge(
        'beeline_subscription_id' => 'sub-existing-55',
        'beeline_subscription_expires_at' => 1.hour.from_now.iso8601
      )
    )

    expect(api_client).to receive(:renew_subscription).with(
      subscription_id: 'sub-existing-55',
      expires: 86_400
    ).and_return({ 'subscriptionId' => 'sub-existing-55', 'expires' => 86_400 })
    expect(api_client).to receive(:statistics).once.and_return([])

    res = described_class.new(channel: voice_channel, api_client: api_client, subscribe_webhook: true).perform
    expect(res[:ok]).to eq(true)
    expect(
      Time.zone.parse(voice_channel.reload.provider_config_hash['beeline_subscription_expires_at'])
    ).to be > 12.hours.from_now
  end

  it 'returns api_token_not_configured when beeline_api_token is missing and handles API errors gracefully' do
    unconfigured_client = instance_double(Telephony::Beeline::ApiClient, configured?: false)
    res = described_class.new(channel: voice_channel, api_client: unconfigured_client).perform
    expect(res).to eq({ ok: false, reason: 'api_token_not_configured', synced: 0, skipped: 0 })

    failing_client = instance_double(Telephony::Beeline::ApiClient, configured?: true)
    allow(failing_client).to receive(:subscribe_webhook).and_return({})
    allow(failing_client).to receive(:statistics).and_raise(
      Telephony::Beeline::ApiClient::ApiError.new('Connection timeout', status: 503)
    )
    err_res = described_class.new(channel: voice_channel, api_client: failing_client, subscribe_webhook: false).perform
    expect(err_res[:ok]).to eq(false)
    expect(err_res[:error]).to include('Connection timeout')
  end
end
