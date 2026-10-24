# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Tasks', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:tasks_path) { "/api/v1/accounts/#{account.id}/captain/tasks" }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def stub_task_service(service_class, payload = { message: 'AI result' })
    service = instance_double(service_class, perform: payload)
    allow(service_class).to receive(:new).and_return(service)
    service
  end

  # The reply-box AI writing tools behind the "Text improvement" switch
  # (captain_features.text_improvement) in AI settings.
  {
    'rewrite' => ['Captain::RewriteService', { content: 'Draft reply', operation: 'improve', conversation_display_id: 1 }],
    'summarize' => ['Captain::SummaryService', { conversation_display_id: 1 }],
    'follow_up' => ['Captain::FollowUpService', { follow_up_context: { event_name: 'rewrite' }, message: 'Shorter', conversation_display_id: 1 }]
  }.each do |action, (service_name, task_params)|
    describe "POST /api/v1/accounts/{account.id}/captain/tasks/#{action}" do
      let(:service_class) { service_name.constantize }

      it 'runs while text improvement was never switched off' do
        stub_task_service(service_class)

        post "#{tasks_path}/#{action}", params: task_params, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
        expect(json_response[:message]).to eq('AI result')
      end

      it 'keeps running for a legacy stored editor=false from the old per-feature switch' do
        account.update!(captain_features: { 'editor' => false })
        stub_task_service(service_class)

        post "#{tasks_path}/#{action}", params: task_params, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:success)
      end

      it 'answers 403 without calling the model when an admin switched text improvement off' do
        account.update!(captain_features: { 'text_improvement' => false })
        allow(service_class).to receive(:new)

        post "#{tasks_path}/#{action}", params: task_params, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:forbidden)
        expect(json_response[:error]).to eq(I18n.t('captain.text_improvement_disabled', locale: account.locale))
        expect(service_class).not_to have_received(:new)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/approve_action and reject_action' do
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }
    let(:approval_service) { instance_double(Captain::ReplySuggestion::ActionApprovalService) }

    before do
      allow(Captain::ReplySuggestion::ActionApprovalService).to receive(:new).with(
        account: account,
        user: agent,
        conversation_display_id: conversation.display_id
      ).and_return(approval_service)
    end

    it 'approves a pending action via Captain::ReplySuggestion::ActionApprovalService' do
      allow(approval_service).to receive(:approve!).with(
        action_id: 'act-123',
        digest: 'dig-abc'
      ).and_return({ 'action_id' => 'act-123', 'status' => 'approved', 'title' => 'Записать на приём' })

      post "#{tasks_path}/approve_action",
           params: {
             conversation_display_id: conversation.display_id,
             action_id: 'act-123',
             digest: 'dig-abc'
           },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:ok]).to be(true)
      expect(json_response.dig(:action, :status)).to eq('approved')
    end

    it 'rejects a pending action via Captain::ReplySuggestion::ActionApprovalService' do
      allow(approval_service).to receive(:reject!).with(
        action_id: 'act-123'
      ).and_return({ 'action_id' => 'act-123', 'status' => 'rejected', 'title' => 'Записать на приём' })

      post "#{tasks_path}/reject_action",
           params: {
             conversation_display_id: conversation.display_id,
             action_id: 'act-123'
           },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:ok]).to be(true)
      expect(json_response.dig(:action, :status)).to eq('rejected')
    end

    it 'returns 404 when action_id is not found' do
      allow(approval_service).to receive(:approve!).and_raise(
        Captain::ReplySuggestion::ActionApprovalService::NotFoundError.new('Not found')
      )

      post "#{tasks_path}/approve_action",
           params: {
             conversation_display_id: conversation.display_id,
             action_id: 'missing-id'
           },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:not_found)
      expect(json_response[:error]).to eq('Not found')
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/feedback' do
    let(:inbox) { create(:inbox, account: account) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox) }

    before { Llm::EventSubscriber.install! }

    it 'records manager copilot feedback in LlmEvent with user attribution and edit outcome' do
      expect do
        post "#{tasks_path}/feedback",
             params: {
               conversation_display_id: conversation.display_id,
               request_id: 'req-copilot-123',
               copilot_action: 'reply_suggestion',
               outcome: 'sent',
               edited_before_send: true,
               follow_up_count: 1,
               message_id: 999,
               generated_text: 'Здравствуйте! Свободное окно в 15:00.',
               final_text: 'Здравствуйте! Можем записать вас сегодня в 15:00.'
             },
             headers: agent.create_new_auth_token,
             as: :json
      end.to change { LlmEvent.where(event_name: 'llm.copilot.feedback').count }.by(1)

      expect(response).to have_http_status(:success)
      expect(json_response[:ok]).to be(true)

      event = LlmEvent.where(event_name: 'llm.copilot.feedback').order(:id).last
      expect(event).to have_attributes(
        account_id: account.id,
        conversation_id: conversation.id,
        request_id: 'req-copilot-123',
        source: 'reply_suggestion',
        status: 'sent'
      )
      expect(event.payload).to include(
        'user_id' => agent.id,
        'user_name' => agent.name,
        'suggestion_outcome' => 'sent',
        'edited_before_send' => true,
        'follow_up_count' => 1,
        'message_id' => 999
      )
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/label_suggestion' do
    it 'keeps label suggestions on their own switch when text improvement is off' do
      account.update!(captain_features: { 'text_improvement' => false, 'label_suggestion' => true })
      stub_task_service(Captain::LabelSuggestionService)

      post "#{tasks_path}/label_suggestion",
           params: { conversation_display_id: 1 },
           headers: agent.create_new_auth_token,
           as: :json

      expect(response).to have_http_status(:success)
      expect(json_response[:message]).to eq('AI result')
    end
  end

  it 'still requires authentication' do
    post "#{tasks_path}/rewrite", params: { content: 'Draft reply', operation: 'improve' }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
