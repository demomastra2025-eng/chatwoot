require 'rails_helper'

RSpec.describe Captain::Tools::Copilot::UpdateDealService do
  let(:account) { create(:account) }
  let(:user) { create(:user, :administrator, account: account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:deal) do
    create(
      :crm_deal,
      account: account,
      originating_conversation_id: conversation.id,
      custom_attributes: { 'lead_source' => 'site' }
    )
  end
  let(:copilot_thread) { create(:captain_copilot_thread, account: account, user: user, assistant: assistant) }
  let(:service) { described_class.new(assistant, user: user, conversation: conversation, copilot_thread: copilot_thread) }

  before do
    account.enable_features!('crm_deals')
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'lead_source', label: 'Lead source', field_type: 'text')
    create(:crm_field_definition, account: account, entity_kind: 'deal', key: 'segment', label: 'Segment', field_type: 'text')
  end

  describe '#execute' do
    it 'updates the current deal using JSON custom_attributes' do
      execute_confirmed(title: 'Renewal won', custom_attributes: { lead_source: 'captain', segment: 'enterprise' }.to_json)

      deal.reload

      expect(deal.title).to eq('Renewal won')
      expect(deal.custom_attributes).to include(
        'lead_source' => 'captain',
        'segment' => 'enterprise'
      )
    end

    it 'updates the current deal from an AI-facing major-unit amount without exposing trailing zero decimals' do
      payload = JSON.parse(execute_confirmed(amount: '200.00', currency: 'USD'))

      deal.reload

      expect(deal.amount_minor).to eq(20_000)
      expect(payload).to include('action' => 'update_deal')
      expect(payload['deal']).to include('id' => deal.id, 'amount' => '200', 'currency' => 'USD')
      expect(payload['deal']).not_to have_key('amount_minor')
    end

    it 'can move the current deal to a pipeline-scoped stage while updating deal fields' do
      target_pipeline = create(:crm_pipeline, account: account, code: 'expansion')
      target_stage = create(:crm_stage, account: account, pipeline: target_pipeline, name: 'В работе', code: 'work', position: 1, color: '#111111')
      create(:crm_stage, account: account, pipeline: deal.pipeline, name: 'В работе', code: 'work', position: 2, color: '#222222')

      execute_confirmed(title: 'Moved renewal', pipeline_code: 'Expansion', stage_code: 'Work')

      deal.reload
      expect(deal.title).to eq('Moved renewal')
      expect(deal.pipeline_id).to eq(target_pipeline.id)
      expect(deal.stage_id).to eq(target_stage.id)
    end

    it 'updates required custom fields before transitioning to a closed stage' do
      create(
        :crm_field_definition,
        account: account,
        entity_kind: 'deal',
        key: 'decision_maker',
        label: 'Decision maker',
        field_type: 'text',
        required: true
      )
      pipeline = deal.pipeline
      won_stage = create(:crm_stage, account: account, pipeline: pipeline, outcome: 'won', code: 'won', color: '#333333')

      payload = JSON.parse(execute_confirmed(stage_id: won_stage.id, custom_attributes: { decision_maker: 'Aruzhan' }.to_json))

      deal.reload
      expect(deal.stage_id).to eq(won_stage.id)
      expect(deal.custom_attributes).to include('decision_maker' => 'Aruzhan')
      expect(payload).to include('action' => 'update_deal')
      expect(payload['deal']).to include('id' => deal.id, 'stage_id' => won_stage.id)
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
