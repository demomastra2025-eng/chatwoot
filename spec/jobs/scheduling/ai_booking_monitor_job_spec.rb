require 'rails_helper'

RSpec.describe Scheduling::AiBookingMonitorJob do
  let(:row) do
    { 'record_type' => 'anomaly', 'account_id' => 7, 'appointment_id' => 12,
      'command_id' => 31, 'rule' => 'A1_CREATE_CRITICAL', 'severity' => 'critical',
      'age_seconds' => 901 }
  end

  it 'logs one safe JSON line for a newly claimed anomaly' do
    report = instance_double(Scheduling::AiBookingReport, call: [row])
    allow(Scheduling::AiBookingReport).to receive(:new).and_return(report)
    allow(Redis::Alfred).to receive(:set).and_return(true, false)
    lines = []
    allow(Rails.logger).to receive(:warn) { |line| lines << line }

    with_modified_env(AI_BOOKING_MONITOR_ENABLED: 'true') do
      described_class.new.perform
      described_class.new.perform
    end

    expect(lines.length).to eq(1)
    payload = JSON.parse(lines.first)
    expect(payload).to include('account_id' => 7, 'appointment_id' => 12, 'rule' => 'A1_CREATE_CRITICAL')
    expect(payload.keys).to match_array(%w[event account_id appointment_id command_id rule severity age_seconds])
  end

  it 'does not query when disabled' do
    with_modified_env(AI_BOOKING_MONITOR_ENABLED: 'false') do
      expect(Scheduling::AiBookingReport).not_to receive(:new)
      described_class.new.perform
    end
  end
end
