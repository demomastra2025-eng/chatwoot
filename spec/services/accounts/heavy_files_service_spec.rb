# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::HeavyFilesService do
  let(:account) { create(:account) }

  describe '#perform' do
    it 'returns empty array when account has no files' do
      service = described_class.new(account: account)
      expect(service.perform).to eq([])
    end

    it 'clamps limit parameter within allowed bounds' do
      service_low = described_class.new(account: account, params: { limit: -5 })
      expect(service_low.send(:limit)).to eq(1)

      service_high = described_class.new(account: account, params: { limit: 500 })
      expect(service_high.send(:limit)).to eq(100)
    end
  end
end
