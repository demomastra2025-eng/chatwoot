require 'rails_helper'

RSpec.describe Meta::ChannelCredentialHealth do
  before do
    stub_request(:any, /graph\.instagram\.com/)
  end

  it { is_expected.to belong_to(:account) }
  it { is_expected.to belong_to(:channel) }
  it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

  it 'rejects a health record scoped to a different account than its channel' do
    channel = create(:channel_instagram)
    health = described_class.new(account: create(:account), channel: channel, status: 'healthy')

    expect(health).not_to be_valid
    expect(health.errors[:account]).to include('must match channel account')
  end

  it 'uses a cascading account foreign key so account deletion cannot be blocked' do
    foreign_keys = ActiveRecord::Base.connection.foreign_keys(described_class.table_name)
    foreign_key = foreign_keys.find { |key| key.to_table == 'accounts' }

    expect(foreign_key.on_delete).to eq(:cascade)
  end

  it 'is deleted with its polymorphic channel' do
    channel = create(:channel_instagram)
    health = described_class.create!(account: channel.account, channel: channel, status: 'healthy')

    channel.destroy!

    expect(described_class.exists?(health.id)).to be(false)
  end
end
