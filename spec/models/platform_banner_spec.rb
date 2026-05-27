require 'rails_helper'

RSpec.describe PlatformBanner do
  describe 'validations' do
    it 'requires a banner message' do
      banner = described_class.new(banner_type: :info, active: true)

      expect(banner).not_to be_valid
      expect(banner.errors[:banner_message]).to be_present
    end
  end

  describe '.active' do
    it 'returns only active banners' do
      active_banner = create(:platform_banner, active: true)
      create(:platform_banner, active: false)

      expect(described_class.active).to contain_exactly(active_banner)
    end
  end
end
