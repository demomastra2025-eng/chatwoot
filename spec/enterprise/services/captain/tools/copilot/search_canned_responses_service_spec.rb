require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::SearchCannedResponsesService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:service) { described_class.new(assistant, user: user) }

  describe '#execute' do
    it 'returns normalized canned responses with filters and total_count before limit' do
      create(:canned_response, account: account, short_code: 'shipping_refund', content: 'Shipping refund policy')
      create(:canned_response, account: account, short_code: 'shipping_terms', content: 'Shipping delivery terms')
      create(:canned_response, account: account, short_code: 'billing', content: 'Billing policy')

      payload = JSON.parse(service.execute(query: 'shipping', limit: 1))

      expect(payload['filters']).to eq('query' => 'shipping')
      expect(payload['total_count']).to eq(2)
      expect(payload['canned_responses'].length).to eq(1)
      expect(payload['canned_responses'].first).to include('short_code' => 'shipping_refund')
    end

    it 'keeps canned responses account scoped' do
      create(:canned_response, account: account, short_code: 'local', content: 'Local response')
      other_account = create(:account)
      create(:canned_response, account: other_account, short_code: 'external', content: 'Local response')

      payload = JSON.parse(service.execute(query: 'response'))

      expect(payload['total_count']).to eq(1)
      expect(payload['canned_responses'].map { |response| response['short_code'] }).to eq(['local'])
    end
  end
end
