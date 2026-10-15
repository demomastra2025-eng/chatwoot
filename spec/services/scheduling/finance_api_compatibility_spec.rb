require 'rails_helper'

RSpec.describe Scheduling::FinanceApiCompatibility do
  around do |example|
    with_modified_env(described_class::ENV_KEY.to_sym => nil) { example.run }
  end

  it 'keeps neutral compatibility fields while no integration anchor is configured' do
    expect(described_class.active?).to be(true)
  end

  it 'keeps compatibility fields and warns once for an invalid anchor without logging its value' do
    invalid_anchor = "invalid-#{SecureRandom.hex(8)}"
    with_modified_env(described_class::ENV_KEY.to_sym => invalid_anchor) do
      expect(Rails.logger).to receive(:warn).once do |message|
        expect(message).to include(described_class::ENV_KEY, 'UTC ISO8601 deployment timestamp')
        expect(message).not_to include(invalid_anchor)
      end

      3.times { expect(described_class.active?).to be(true) }
    end
  end

  it 'starts the configured window at the future integration timestamp' do
    anchor = Time.current.utc.change(usec: 0) + 10.days
    with_modified_env(described_class::ENV_KEY.to_sym => anchor.iso8601) do
      travel_to(anchor - 1.day) { expect(described_class.active?).to be(true) }
      travel_to(anchor) { expect(described_class.active?).to be(true) }
    end
  end

  it 'keeps compatibility before the seven-day cutoff and removes it at and after the cutoff' do
    anchor = Time.current.utc.change(usec: 0) + 10.days
    with_modified_env(described_class::ENV_KEY.to_sym => anchor.iso8601) do
      travel_to(anchor + described_class::WINDOW_SECONDS - 1) { expect(described_class.active?).to be(true) }
      travel_to(anchor + described_class::WINDOW_SECONDS) { expect(described_class.active?).to be(false) }
      travel_to(anchor + described_class::WINDOW_SECONDS + 1) { expect(described_class.active?).to be(false) }
    end
  end

  it 'rejects anchors without an explicit UTC timezone' do
    with_modified_env(described_class::ENV_KEY.to_sym => '2030-01-15T12:00:00') do
      expect(Rails.logger).to receive(:warn).once
      expect(described_class.active?).to be(true)
    end
  end
end
