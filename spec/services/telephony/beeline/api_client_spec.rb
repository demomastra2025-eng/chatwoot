# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Telephony::Beeline::ApiClient do
  let(:api_token) { 'beeline-mpbx-token-secret' }
  let(:base_url) { 'https://cloudpbx.beeline.kz/apis/portal' }
  let(:client) { described_class.new(api_token: api_token, base_url: base_url) }

  describe '#configured?' do
    it 'returns true when api_token is present and false when blank' do
      expect(client.configured?).to be(true)
      expect(described_class.new(api_token: '').configured?).to be(false)
      expect(described_class.new(api_token: nil).configured?).to be(false)
    end
  end

  describe '#abonents' do
    it 'fetches /abonents with X-MPBX-API-AUTH-TOKEN header' do
      stub_request(:get, "#{base_url}/abonents")
        .with(headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token })
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: [{ userId: 'SIP_201@vpbx.beeline.kz', extension: '201' }].to_json
        )

      result = client.abonents
      expect(result).to eq([{ 'userId' => 'SIP_201@vpbx.beeline.kz', 'extension' => '201' }])
    end
  end

  describe '#subscribe_webhook, #renew_subscription, and #subscription_status' do
    it 'creates, renews, and checks a Xsi-Events webhook subscription' do
      stub_request(:post, "#{base_url}/subscription")
        .with(
          headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token, 'Content-Type' => 'application/json' },
          body: {
            url: 'https://dev.one-link.kz/beeline/events/tok-1',
            expires: 86_400,
            subscriptionType: 'BASIC_CALL'
          }.to_json
        )
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { subscriptionId: 'sub-123', expires: 86_400 }.to_json
        )

      sub = client.subscribe_webhook(url: 'https://dev.one-link.kz/beeline/events/tok-1', expires: 86_400)
      expect(sub).to eq({ 'subscriptionId' => 'sub-123', 'expires' => 86_400 })

      stub_request(:put, "#{base_url}/subscription")
        .with(
          headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token, 'Content-Type' => 'application/json' },
          body: { subscriptionId: 'sub-123', expires: 86_400 }.to_json
        )
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { subscriptionId: 'sub-123', expires: 86_400 }.to_json
        )

      renewed = client.renew_subscription(subscription_id: 'sub-123', expires: 86_400)
      expect(renewed).to eq({ 'subscriptionId' => 'sub-123', 'expires' => 86_400 })

      stub_request(:get, "#{base_url}/subscription")
        .with(
          query: { 'subscriptionId' => 'sub-123' },
          headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token }
        )
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { subscriptionId: 'sub-123', expires: 72_000, targetId: 'company-1' }.to_json
        )

      status = client.subscription_status('sub-123')
      expect(status).to include('subscriptionId' => 'sub-123', 'expires' => 72_000)
    end
  end

  describe '#statistics' do
    it 'fetches /v2/statistics and falls back to /statistics when /v2/statistics returns 404' do
      date_from = Time.zone.parse('2026-10-17 10:00:00')
      date_to = Time.zone.parse('2026-10-17 11:00:00')

      stub_request(:get, "#{base_url}/v2/statistics")
        .with(
          query: {
            'dateFrom' => date_from.utc.iso8601,
            'dateTo' => date_to.utc.iso8601,
            'page' => '0',
            'pageSize' => '100'
          },
          headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token }
        )
        .to_return(status: 404, body: 'Not Found')

      stub_request(:get, "#{base_url}/statistics")
        .with(
          query: {
            'dateFrom' => date_from.utc.iso8601,
            'dateTo' => date_to.utc.iso8601,
            'page' => '0',
            'pageSize' => '100'
          },
          headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token }
        )
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: [{ id: 'stat-1', direction: 'INBOUND', status: 'MISSED', phone: '+77015554433' }].to_json
        )

      records = client.statistics(date_from: date_from, date_to: date_to, page: 0, page_size: 100)
      expect(records).to eq([{ 'id' => 'stat-1', 'direction' => 'INBOUND', 'status' => 'MISSED', 'phone' => '+77015554433' }])
    end
  end

  describe '#download_recording' do
    it 'downloads direct binary audio from /v2/records/:id/download' do
      stub_request(:get, "#{base_url}/v2/records/rec-99/download")
        .with(headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token })
        .to_return(
          status: 200,
          headers: {
            'Content-Type' => 'audio/mpeg',
            'Content-Disposition' => 'attachment; filename="call-99.mp3"'
          },
          body: 'MP3_BINARY_DATA'
        )

      recording = client.download_recording('rec-99')
      expect(recording).to eq(
        body: 'MP3_BINARY_DATA',
        content_type: 'audio/mpeg',
        filename: 'call-99.mp3'
      )
    end

    it 'falls back to /records/:id/reference when download endpoints return 404 and fetches the signed URL' do
      stub_request(:get, "#{base_url}/v2/records/rec-ref-1/download")
        .to_return(status: 404, body: 'Not Found')
      stub_request(:get, "#{base_url}/records/rec-ref-1/download")
        .to_return(status: 404, body: 'Not Found')
      stub_request(:get, "#{base_url}/records/rec-ref-1/reference")
        .with(headers: { 'X-MPBX-API-AUTH-TOKEN' => api_token })
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: { url: 'https://storage.cloudpbx.beeline.kz/audio/rec-ref-1.mp3' }.to_json
        )
      stub_request(:get, 'https://storage.cloudpbx.beeline.kz/audio/rec-ref-1.mp3')
        .to_return(
          status: 200,
          headers: { 'Content-Type' => 'audio/mp3' },
          body: 'SIGNED_URL_MP3_BYTES'
        )

      recording = client.download_recording('rec-ref-1')
      expect(recording[:body]).to eq('SIGNED_URL_MP3_BYTES')
      expect(recording[:content_type]).to eq('audio/mp3')
      expect(recording[:filename]).to eq('beeline-rec-ref-1.mp3')
    end
  end

  describe 'error handling' do
    it 'raises ApiError with HTTP status when Beeline API returns an error status' do
      stub_request(:get, "#{base_url}/abonents")
        .to_return(status: 401, body: 'Invalid token')

      expect { client.abonents }.to raise_error(Telephony::Beeline::ApiClient::ApiError) do |error|
        expect(error.status).to eq(401)
        expect(error.message).to include('401')
      end
    end
  end
end
