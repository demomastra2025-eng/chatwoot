require 'rails_helper'

RSpec.describe SuperAdmin::DashboardAlerts::Medelement do
  let(:account) { create(:account) }
  let(:hook) { create(:integrations_hook, :medelement, account: account) }

  before { account.enable_features!('scheduling') }

  it 'raises the platform alert at the configured hourly 429 threshold' do
    hook.update!(settings: hook.settings.merge('rate_alert_threshold_per_hour' => 2))
    hour = Time.current.utc.strftime('%Y%m%d%H')
    rows = [{ hour: hour, hook_id: hook.id.to_s, status: '429', count: 2 }]
    allow(Integrations::Medelement::RequestTelemetry).to receive(:report).with(hours: 1).and_return(rows)

    alert = described_class.new.alerts.sole
    expect(alert).to include(key: 'medelement', severity: :danger, count: 1)
    expect(alert[:items].sole[:note]).to include('2')
  end
end
