require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateDealService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:deal) do
    create(
      :crm_deal,
      account: account,
      originating_conversation_id: conversation.id,
      custom_attributes: { 'source' => 'site' }
    )
  end
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_deals')
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'source', label: 'Source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'segment', label: 'Segment', field_type: 'text')
  end

  describe '#execute' do
    it 'updates the current deal using object custom_attributes' do
      service.execute(title: 'Renewal won', custom_attributes: { 'source' => 'captain', 'segment' => 'enterprise' })

      deal.reload

      expect(deal.title).to eq('Renewal won')
      expect(deal.custom_attributes).to include(
        'source' => 'captain',
        'segment' => 'enterprise'
      )
    end

    it 'updates the current deal from an AI-facing major-unit amount without exposing trailing zero decimals' do
      result = service.execute(amount: '200.00', currency: 'USD')

      deal.reload

      expect(deal.amount_minor).to eq(20_000)
      expect(result).to include('Amount: 200 USD')
      expect(result).not_to include('Amount Minor')
      expect(result).not_to include('20000')
    end
  end
end
