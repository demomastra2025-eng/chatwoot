require 'rails_helper'

RSpec.describe Meta::ChannelCredentialHealthRecorder do
  let(:channel) do
    create(:channel_instagram, access_token: 'ig-token', expires_at: 20.days.from_now, updated_at: 1.day.ago)
  end

  it 'recovers a real collision inside the channel lock transaction' do
    health = Meta::ChannelCredentialHealth.create!(account: channel.account, channel: channel, status: 'unknown')
    scope = Meta::ChannelCredentialHealth.where(channel: channel)
    stale_health_lookup = true
    database_collision = false

    allow(Meta::ChannelCredentialHealth).to receive(:where).and_call_original
    allow(Meta::ChannelCredentialHealth).to receive(:where).with(channel: channel).and_return(scope)
    allow(scope).to receive(:first).and_wrap_original do |original|
      if stale_health_lookup
        stale_health_lookup = false
        nil
      else
        original.call
      end
    end
    allow(scope).to receive(:create!) do |attributes|
      scope.new(attributes).save!(validate: false)
    rescue ActiveRecord::RecordNotUnique
      database_collision = true
      raise
    end

    result = Meta::AuthorizationHealthCheckService::Result.new(status: :healthy, reason: 'healthy')

    channel.with_lock do
      expect(described_class.new(channel).record_result!(result)).to eq(health)
      expect(database_collision).to be(true)
      expect(ActiveRecord::Base.connection.select_value('SELECT 1')).to eq(1)
    end

    expect(health.reload.status).to eq('healthy')
  end
end
