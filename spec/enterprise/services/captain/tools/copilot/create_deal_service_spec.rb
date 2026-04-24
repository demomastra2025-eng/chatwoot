require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateDealService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:company) { create(:company, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation) }

  before do
    account.enable_features!('crm_deals')
    contact.update!(company: company)
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'lead_source', label: 'Lead source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'priority_band', label: 'Priority band', field_type: 'text')
  end

  describe '#execute' do
    it 'creates a deal using object custom_attributes' do
      service.execute(
        title: 'Enterprise expansion',
        currency: 'USD',
        amount_minor: 250_000,
        custom_attributes: { 'lead_source' => 'captain', 'priority_band' => 'high' }
      )

      deal = account.crm_deals.order(:id).last

      expect(deal.title).to eq('Enterprise expansion')
      expect(deal.amount_minor).to eq(250_000)
      expect(deal.primary_contact_id).to eq(contact.id)
      expect(deal.company_id).to eq(company.id)
      expect(deal.originating_conversation_id).to eq(conversation.id)
      expect(deal.custom_attributes).to include(
        'lead_source' => 'captain',
        'priority_band' => 'high'
      )
    end
  end
end
