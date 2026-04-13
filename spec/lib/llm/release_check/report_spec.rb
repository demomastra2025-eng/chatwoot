# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::ReleaseCheck::Report do
  it 'returns fail when a blocking check exists' do
    report = described_class.new(
      generated_at: Time.zone.parse('2026-04-10 12:00:00'),
      account_id: 42,
      date_range: nil,
      filters: {},
      operational: {},
      evals: {},
      checks: [
        { name: 'operational_release_gate', status: 'fail', blocking: true }
      ]
    )

    expect(report.status).to eq('fail')
    expect(report.passed?).to be(false)
    expect(report.blocking_failures).to eq([{ name: 'operational_release_gate', status: 'fail', blocking: true }])
  end

  it 'returns pass_with_warnings when checks are advisory only' do
    report = described_class.new(
      generated_at: Time.zone.parse('2026-04-10 12:00:00'),
      account_id: 42,
      date_range: nil,
      filters: {},
      operational: {},
      evals: {},
      checks: [
        { name: 'operational_release_gate', status: 'insufficient_data', blocking: false },
        { name: 'deterministic_evals', status: 'pass', blocking: false }
      ]
    )

    expect(report.status).to eq('pass_with_warnings')
    expect(report.passed?).to be(true)
  end
end
