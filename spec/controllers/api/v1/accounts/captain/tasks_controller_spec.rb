# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::Captain::Tasks', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:tasks_path) { "/api/v1/accounts/#{account.id}/captain/tasks" }

  def json_response
    JSON.parse(response.body, symbolize_names: true)
  end

  def stub_task_service(service_class)
    service = instance_double(service_class, perform: { message: 'AI result' })
    allow(service_class).to receive(:new).and_return(service)
    service
  end

  # The reply-box AI writing tools behind the "Text improvement" switch
  # (captain_features.editor) in AI settings.
  {
    'rewrite' => ['Captain::RewriteService', { content: 'Draft reply', operation: 'improve', conversation_display_id: 1 }],
    'summarize' => ['Captain::SummaryService', { conversation_display_id: 1 }],
    'reply_suggestion' => ['Captain::ReplySuggestionService', { conversation_display_id: 1 }],
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

      it 'answers 403 without calling the model when an admin switched text improvement off' do
        account.update!(captain_features: { 'editor' => false })
        allow(service_class).to receive(:new)

        post "#{tasks_path}/#{action}", params: task_params, headers: agent.create_new_auth_token, as: :json

        expect(response).to have_http_status(:forbidden)
        expect(json_response[:error]).to eq(I18n.t('captain.text_improvement_disabled', locale: account.locale))
        expect(service_class).not_to have_received(:new)
      end
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/captain/tasks/label_suggestion' do
    it 'keeps label suggestions on their own switch when text improvement is off' do
      account.update!(captain_features: { 'editor' => false, 'label_suggestion' => true })
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
