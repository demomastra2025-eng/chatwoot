require 'rails_helper'

RSpec.describe SuperAdmin::GrafanaDashboards do
  it 'uses canonical dashboard UIDs when no installation override exists' do
    allow(GlobalConfigService).to receive(:load) { |_key, default| default }

    expect(described_class.uid(:overview)).to eq('onelink-production-overview')
    expect(described_class.path(:logs)).to include('/d/onelink-production-logs/onelink-production-logs?')
  end

  it 'maps only the two known legacy defaults and preserves operator dashboards' do
    allow(GlobalConfigService).to receive(:load).and_return('crafty-production-overview')
    expect(described_class.uid(:overview)).to eq('onelink-production-overview')

    allow(GlobalConfigService).to receive(:load).and_return('team-custom-dashboard')
    expect(described_class.uid(:overview)).to eq('team-custom-dashboard')
  end

  it 'rejects invalid URL input and keeps the canonical fallback' do
    allow(GlobalConfigService).to receive(:load).and_return('../invalid?redirect=example')

    expect(described_class.embed_path(:overview)).to end_with('&kiosk=tv')
    expect(described_class.uid(:overview)).to eq('onelink-production-overview')
  end
end
