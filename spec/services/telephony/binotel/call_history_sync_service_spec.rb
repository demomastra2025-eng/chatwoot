# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Binotel::CallHistorySyncService do
  let(:account) { create(:account) }
  let(:operator) { create(:user, account: account, role: :administrator) }
  let(:provider_connection) do
    create(
      :telephony_provider_connection,
      account: account,
      provider_kind: 'binotel',
      host: 'sip53.binotel.com',
      port: 5060,
      transport: 'udp',
      username: 'binotel-company-1'
    )
  end
  let(:voice_channel) do
    create(
      :channel_voice,
      account: account,
      provider: 'binotel',
      phone_number: '+77007585522',
      provider_config: {
        'provider_kind' => 'binotel',
        'provider_connection_id' => provider_connection.id,
        'number_ref' => 'binotel-main-line',
        'binotel_api_key' => 'rest-key-123',
        'binotel_api_secret' => 'rest-secret-456',
        'routing_mode' => 'operator',
        'operator_distribution_mode' => 'broadcast'
      }
    )
  end
  let(:voice_inbox) { voice_channel.inbox }
  let(:number_binding) { Telephony::NumberBinding.sync_from_voice_channel!(voice_channel) }

  before do
    account.enable_features!('channel_voice')
    create(:inbox_member, inbox: voice_inbox, user: operator)
    number_binding
  end

  it 'auto-generates binotel_events_webhook_token on Binotel channel creation and excludes API secrets from number_binding metadata' do
    expect(voice_channel.provider_config_hash['binotel_events_webhook_token']).to be_present
    expect(number_binding.reload.metadata).not_to have_key('binotel_api_key')
    expect(number_binding.reload.metadata).not_to have_key('binotel_api_secret')
  end

  it 'syncs missed (CANCEL, VM-SUCCESS, NOANSWER) and answered calls from Binotel API idempotently' do
    now = Time.zone.parse('2026-10-19 03:30:00 +0500')
    api_client = instance_double(Telephony::Binotel::ApiClient, configured?: true)
    allow(api_client).to receive(:list_of_calls_for_period).and_return(
      'status' => 'success',
      'callDetails' => {
        '6930126319' => {
          'generalCallID' => '6930126319',
          'startTime' => (now - 20.minutes).to_i.to_s,
          'callType' => '0',
          'internalNumber' => '902',
          'externalNumber' => '07071112233',
          'waitsec' => 129,
          'billsec' => 0,
          'disposition' => 'VM-SUCCESS',
          'pbxNumberData' => { 'number' => '77007585522' }
        },
        '6930126320' => {
          'generalCallID' => '6930126320',
          'startTime' => (now - 15.minutes).to_i.to_s,
          'callType' => '0',
          'internalNumber' => '901',
          'externalNumber' => '77012223344',
          'waitsec' => 18,
          'billsec' => 0,
          'disposition' => 'CANCEL',
          'pbxNumberData' => { 'number' => '77007585522' }
        },
        '6930126321' => {
          'generalCallID' => '6930126321',
          'startTime' => (now - 10.minutes).to_i.to_s,
          'callType' => '0',
          'internalNumber' => '902',
          'externalNumber' => '+77023334455',
          'waitsec' => 4,
          'billsec' => 42,
          'disposition' => 'ANSWER',
          'pbxNumberData' => { 'number' => '77007585522' }
        }
      }
    )

    first_run = described_class.new(channel: voice_channel, api_client: api_client, now: now).perform
    expect(first_run).to include(ok: true, fetched: 3, ingested: 3, skipped: 0)

    vm_call = account.telephony_call_sessions.find_by!(provider_call_sid: '6930126319')
    expect(vm_call).to have_attributes(
      status: 'missed',
      direction: 'inbound',
      from_number: '+77071112233',
      to_number: '+77007585522',
      answered_at: nil,
      duration_seconds: 129,
      end_reason: 'VM-SUCCESS'
    )

    cancel_call = account.telephony_call_sessions.find_by!(provider_call_sid: '6930126320')
    expect(cancel_call).to have_attributes(
      status: 'missed',
      direction: 'inbound',
      from_number: '+77012223344',
      to_number: '+77007585522',
      answered_at: nil,
      duration_seconds: 18,
      end_reason: 'CANCEL'
    )

    answered_call = account.telephony_call_sessions.find_by!(provider_call_sid: '6930126321')
    expect(answered_call).to have_attributes(
      status: 'completed',
      direction: 'inbound',
      from_number: '+77023334455',
      to_number: '+77007585522',
      duration_seconds: 42,
      end_reason: 'ANSWER'
    )
    expect(answered_call.answered_at).to be_present

    second_run = described_class.new(channel: voice_channel, api_client: api_client, now: now + 1.minute).perform
    expect(second_run).to include(ok: true, fetched: 3, ingested: 0, skipped: 3)
    expect(account.telephony_call_sessions.where(provider: 'binotel').count).to eq(3)
    expect(voice_channel.reload.provider_config_hash['binotel_last_synced_at']).to eq((now + 1.minute).iso8601)
  end

  it 'returns api_credentials_not_configured when credentials are missing' do
    voice_channel.update!(
      provider_config: voice_channel.provider_config_hash.except('binotel_api_key', 'binotel_api_secret')
    )

    result = described_class.new(channel: voice_channel).perform
    expect(result).to eq(ok: false, reason: 'api_credentials_not_configured')
  end
end
