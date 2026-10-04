# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountLimits::StorageAlertService, type: :service do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:service) { described_class.new(account: account) }
  let(:storage_usage_service) { instance_double(AccountLimits::StorageUsageService) }

  before do
    admin # Ensure admin exists
    allow(AccountLimits::StorageUsageService).to receive(:new).with(account: account).and_return(storage_usage_service)
    allow(storage_usage_service).to receive(:unlimited?).and_return(false)
    allow(storage_usage_service).to receive(:total_limit_bytes).and_return(10.gigabytes)
    allow(storage_usage_service).to receive(:usage_bytes).and_return(5.gigabytes)

    allow(Redis::Alfred).to receive(:get).and_return(nil)
    allow(Redis::Alfred).to receive(:set)
    allow(Redis::Alfred).to receive(:setex)
    allow(Redis::Alfred).to receive(:delete)
  end

  describe '#perform' do
    context 'when account has unlimited storage' do
      it 'returns unlimited status without sending alerts' do
        allow(storage_usage_service).to receive(:unlimited?).and_return(true)

        res = service.perform
        expect(res[:status]).to eq(:unlimited)
        expect(res[:alert_sent]).to be(false)
      end
    end

    context 'when storage usage is below 80%' do
      it 'returns normal status and clears alert level' do
        allow(storage_usage_service).to receive(:usage_bytes).and_return(5.gigabytes)

        res = service.perform
        expect(res[:status]).to eq(:normal)
        expect(res[:alert_sent]).to be(false)
      end
    end

    context 'when storage usage is between 80% and 95%' do
      it 'records an in-app warning and stores the 24-hour debounce timestamp in Redis' do
        allow(storage_usage_service).to receive(:usage_bytes).and_return(8.5.gigabytes)

        expect(Rails.logger).to receive(:info)
          .with("[StorageAlertService] In-app warning storage warning for account #{account.id} at 85.0%")
        expect(Redis::Alfred).to receive(:setex)
          .with("account:#{account.id}:storage_alert_sent_at:warning", 24.hours.to_i, kind_of(String))
        expect(Redis::Alfred).to receive(:set)
          .with("account:#{account.id}:storage_alert_level", 'warning')

        res = service.perform
        expect(res[:status]).to eq(:warning)
        expect(res[:alert_sent]).to be(true)
      end

      it 'throttles alert if sent within last 24 hours' do
        allow(storage_usage_service).to receive(:usage_bytes).and_return(8.5.gigabytes)
        allow(Redis::Alfred).to receive(:get)
          .with("account:#{account.id}:storage_alert_sent_at:warning")
          .and_return(2.hours.ago.to_i.to_s)

        expect(Rails.logger).not_to receive(:info)
          .with("[StorageAlertService] In-app warning storage warning for account #{account.id} at 85.0%")

        res = service.perform
        expect(res[:status]).to eq(:warning)
        expect(res[:alert_sent]).to be(false)
        expect(res[:throttled]).to be(true)
      end
    end

    context 'when storage usage is 95% or higher' do
      it 'records an in-app critical warning without activating email delivery' do
        allow(storage_usage_service).to receive(:usage_bytes).and_return(9.6.gigabytes)

        expect(Rails.logger).to receive(:info)
          .with("[StorageAlertService] In-app critical storage warning for account #{account.id} at 96.0%")
        expect(Redis::Alfred).to receive(:setex)
          .with("account:#{account.id}:storage_alert_sent_at:critical", 24.hours.to_i, kind_of(String))

        res = service.perform
        expect(res[:status]).to eq(:critical)
        expect(res[:alert_sent]).to be(true)
      end
    end
  end

  describe '.check_all_accounts!' do
    it 'checks accounts with storage limits' do
      account.update!(limits: { 'storage_bytes' => 10.gigabytes })
      service_instance = instance_double(described_class, perform: { alert_sent: true })
      allow(described_class).to receive(:new).with(account: account).and_return(service_instance)

      results = described_class.check_all_accounts!
      expect(results[:checked]).to be >= 1
      expect(results[:alerts_sent]).to be >= 1
    end
  end
end
