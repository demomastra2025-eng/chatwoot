# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccountLimits::StorageUsageService do
  let(:account) { create(:account) }

  describe '#summary' do
    subject(:summary) { described_class.new(account: account).summary }

    it 'marks storage as unlimited when no account or global limit is configured' do
      expect(summary).to include(
        total_count: ChatwootApp.max_limit,
        current_available: ChatwootApp.max_limit,
        consumed: 0,
        unlimited: true
      )
    end

    it 'treats an explicit storage limit as bounded even when it matches the sentinel value' do
      account.update!(limits: { 'storage_bytes' => ChatwootApp.max_limit })

      expect(summary).to include(
        total_count: ChatwootApp.max_limit,
        current_available: ChatwootApp.max_limit,
        consumed: 0,
        unlimited: false
      )
    end
  end
end
