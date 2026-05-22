require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::CreateDealService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:company) { create(:company, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  before do
    account.enable_features!('crm_deals')
    contact.update!(company: company)
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'lead_source', label: 'Lead source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'priority_band', label: 'Priority band', field_type: 'text')
  end

  describe '#execute' do
    it 'creates a deal using JSON custom_attributes' do
      execute_confirmed(
        title: 'Enterprise expansion',
        currency: 'USD',
        amount: '2500',
        custom_attributes: { lead_source: 'captain', priority_band: 'high' }.to_json
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

    it 'creates a deal from an AI-facing major-unit amount without exposing trailing zero decimals' do
      payload = JSON.parse(execute_confirmed(title: 'Whole amount deal', currency: 'USD', amount: '200.00'))

      deal = account.crm_deals.order(:id).last

      expect(deal.amount_minor).to eq(20_000)
      expect(payload).to include('action' => 'create_deal')
      expect(payload['deal']).to include('id' => deal.id, 'amount' => '200', 'currency' => 'USD')
      expect(payload['deal']).not_to have_key('amount_minor')
    end

    it 'creates a deal in a selected non-default pipeline and stage' do
      default_pipeline = create(:crm_pipeline, account: account, name: 'Andalusiya', code: 'andalusiya', default: true)
      create(:crm_stage, account: account, pipeline: default_pipeline, name: 'Новый', code: 'new', position: 1, color: '#111111')
      target_pipeline = create(:crm_pipeline, account: account, name: 'Andalusiya2', code: 'andalusiya2')
      target_stage = create(:crm_stage, account: account, pipeline: target_pipeline, name: 'Новый', code: 'new', position: 1, color: '#222222')

      execute_confirmed(title: 'Pipeline-specific deal', pipeline_code: 'andalusiya2', stage_code: 'new')

      deal = account.crm_deals.order(:id).last
      expect(deal.pipeline_id).to eq(target_pipeline.id)
      expect(deal.stage_id).to eq(target_stage.id)
    end
  end

  def execute_confirmed(**arguments)
    first_result = service.execute(**arguments)
    first_payload = JSON.parse(first_result)
    return first_result unless first_payload.dig('data', 'confirmation_required')

    confirmation_token = copilot_thread.copilot_messages.assistant_thinking.last.message.dig('confirmation_gate', 'confirmation_token')

    create(
      :captain_copilot_message,
      account: account,
      copilot_thread: copilot_thread,
      message_type: 'user',
      message: { 'content' => "Подтверждаю #{confirmation_token}" }
    )

    service.execute(**arguments)
  end
end
