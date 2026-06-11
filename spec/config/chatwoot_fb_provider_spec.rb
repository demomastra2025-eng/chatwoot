require 'rails_helper'

RSpec.describe ChatwootFbProvider do
  subject(:provider) { described_class.new }

  let(:page_id) { 'page-123' }

  before do
    allow(GlobalConfigService).to receive(:load).with('FB_APP_SECRET', '').and_return('global-secret')
  end

  def stub_facebook_channel(channel)
    relation = instance_double(ActiveRecord::Relation, last: channel)
    allow(Channel::FacebookPage).to receive(:where).with(page_id: page_id).and_return(relation)
  end

  describe '#app_secret_for' do
    it 'uses the channel app secret before the global secret' do
      channel = Struct.new(:app_secret).new('channel-secret')
      stub_facebook_channel(channel)

      expect(provider.app_secret_for(page_id)).to eq('channel-secret')
    end

    it 'uses provider config app secret aliases before the global secret' do
      channel = Struct.new(:provider_config).new({ 'client_secret' => 'provider-secret' })
      stub_facebook_channel(channel)

      expect(provider.app_secret_for(page_id)).to eq('provider-secret')
    end

    it 'falls back to the global Facebook app secret' do
      stub_facebook_channel(nil)

      expect(provider.app_secret_for(page_id)).to eq('global-secret')
    end
  end
end
