require 'rails_helper'

RSpec.describe Crm::WorkspaceTimezone do
  it 'uses the account reporting timezone as a canonical timezone identifier' do
    account = build(:account, settings: { 'reporting_timezone' => 'Eastern Time (US & Canada)' })

    expect(described_class.resolve(account)).to eq('America/New_York')
  end

  it 'uses the CRM default when the account has no supported reporting timezone' do
    account = build(:account, settings: { 'reporting_timezone' => 'invalid-zone' })

    expect(described_class.resolve(account)).to eq('Asia/Almaty')
  end
end
