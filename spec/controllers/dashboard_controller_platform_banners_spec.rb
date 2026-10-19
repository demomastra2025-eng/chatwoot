require 'rails_helper'

RSpec.describe DashboardController, type: :controller do
  describe '#active_platform_banners' do
    it 'returns active banners for global config' do
      inactive_banner = create(:platform_banner, active: false)
      older_banner = create(
        :platform_banner,
        banner_message: 'Older outage',
        banner_type: :warning,
        created_at: 2.days.ago
      )
      newer_banner = create(
        :platform_banner,
        banner_message: 'Current outage',
        banner_type: :error,
        created_at: 1.day.ago
      )

      payload = controller.send(:active_platform_banners)

      expect(payload.pluck('id')).to eq([newer_banner.id, older_banner.id])
      expect(payload.pluck('id')).not_to include(inactive_banner.id)
      expect(payload.first).to include(
        'banner_message' => 'Current outage',
        'banner_type' => 'error'
      )
    end

    it 'returns the banners of a self-hosted installation as well, not only of the cloud' do
      allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(false)
      banner = create(:platform_banner, banner_message: 'Технические работы в субботу')

      expect(controller.send(:active_platform_banners).pluck('id')).to eq([banner.id])
    end

    it 'degrades safely before the platform banners table is available' do
      allow(PlatformBanner).to receive(:table_exists?).and_return(false)

      expect(controller.send(:active_platform_banners)).to eq([])
    end
  end
end
