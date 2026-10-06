require 'rails_helper'

RSpec.describe Meta::ChannelCredentialHealthRecorder do
  let(:channel) do
    create(:channel_instagram, access_token: 'ig-token', expires_at: 20.days.from_now, updated_at: 1.day.ago)
  end

  it 'uses Rails create_or_find_by! recovery for a real collision inside the channel lock transaction' do
    health = Meta::ChannelCredentialHealth.create!(account: channel.account, channel: channel, status: 'unknown')
    stale_health_lookup = true
    database_collision = false

    allow_any_instance_of(Meta::ChannelCredentialHealth).to receive(:valid?).and_return(true)
    allow_any_instance_of(ActiveRecord::Relation).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
      relation = original.receiver
      if relation.klass == Meta::ChannelCredentialHealth && stale_health_lookup
        stale_health_lookup = false
        nil
      else
        original.call(*args, **kwargs)
      end
    end
    allow_any_instance_of(ActiveRecord::Relation).to receive(:create!).and_wrap_original do |original, *args, **kwargs, &block|
      relation = original.receiver
      begin
        original.call(*args, **kwargs, &block)
      rescue ActiveRecord::RecordNotUnique
        database_collision = true if relation.klass == Meta::ChannelCredentialHealth
        raise
      end
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
