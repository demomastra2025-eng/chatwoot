require 'rails_helper'

RSpec.describe LlmFormatter::Crm::DealLlmFormatter do
  let(:account) { create(:account) }

  describe '#format' do
    it 'formats whole amounts for AI without trailing zero decimals or minor-unit noise' do
      deal = create(:crm_deal, account: account, amount_minor: 20_000, currency: 'USD')

      output = described_class.new(deal).format

      expect(output).to include('Amount: 200 USD')
      expect(output).not_to include('Amount Minor')
      expect(output).not_to include('20000')
    end
  end
end
