require 'rails_helper'

RSpec.describe Api::V1::InboxesHelper, type: :helper do
  describe '#inbox_name' do
    it 'uses generated Weixin inbox name instead of requiring a top-level name' do
      channel = build(:channel_weixin, display_name: 'Main WeChat')

      expect(helper.inbox_name(channel)).to eq('Main WeChat')
    end

    it 'falls back to the default Weixin inbox name when display name is omitted' do
      channel = build(:channel_weixin, display_name: nil, provider_account_id: nil)

      expect(helper.inbox_name(channel)).to eq('Weixin Personal')
    end
  end
end
