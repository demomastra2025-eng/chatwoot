require 'rails_helper'

RSpec.describe Channel::VkCommunity do
  around do |example|
    with_modified_env('FRONTEND_URL' => 'https://app.example.com') do
      example.run
    end
  end

  describe 'defaults and derived fields' do
    it 'uses generated callback id and callback url' do
      channel = create(:channel_vk_community, callback_id: nil)

      expect(channel.callback_id).to be_present
      expect(channel.callback_webhook_url).to eq(
        "https://app.example.com/webhooks/vk/#{channel.callback_id}"
      )
      expect(channel.generated_inbox_name).to eq("vk_#{channel.group_id}")
    end
  end

  describe 'runtime identity updates' do
    it 'does not allow changing group_id after creation' do
      channel = create(:channel_vk_community)

      expect(channel.update(group_id: channel.group_id + 1)).to be(false)
      expect(channel.errors[:group_id]).to include('cannot be changed after creation')
    end
  end
end
