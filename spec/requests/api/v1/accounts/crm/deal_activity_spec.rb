require 'rails_helper'

RSpec.describe 'CRM Deal Activity API', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:headers) { administrator.create_new_auth_token }
  let(:deal_path) { "/api/v1/accounts/#{account.id}/crm/deals" }

  before do
    account.enable_features!('crm_deals')
    Crm::Bootstrap::AccountService.new(account: account).perform
  end

  it 'creates, updates, lists, and soft-deletes deal comments' do
    deal = create(:crm_deal, account: account, company: create(:company, account: account))
    comments_path = "#{deal_path}/#{deal.id}/comments"

    post comments_path, params: { body: 'Need pricing approval' }, headers: headers, as: :json

    expect(response).to have_http_status(:created)
    comment_id = response.parsed_body.dig('payload', 'id')

    patch "#{comments_path}/#{comment_id}",
          params: { body: 'Need pricing approval from finance' },
          headers: headers,
          as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('payload', 'body')).to eq('Need pricing approval from finance')

    get comments_path, headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('meta', 'count')).to eq(1)

    delete "#{comments_path}/#{comment_id}", headers: headers, as: :json

    expect(response).to have_http_status(:ok)
    expect(deal.comments.find(comment_id).deleted_at).to be_present
  end

  it 'returns timeline items with events, comments, and only permission-scoped conversations' do
    pipeline = account.crm_pipelines.find_by!(code: 'sales_pipeline')
    stage = pipeline.stages.find_by!(code: 'new')
    agent = create(:user, account: account, role: :agent)
    custom_role = create(
      :custom_role,
      account: account,
      permissions: %w[crm_deal_view conversation_participating_manage]
    )
    agent.account_users.find_by(account: account).update!(custom_role: custom_role)
    allowed_inbox = create(:inbox, account: account, channel: create(:channel_widget, account: account))
    blocked_inbox = create(:inbox, account: account, channel: create(:channel_widget, account: account))
    create(:inbox_member, inbox: allowed_inbox, user: agent)

    contact = create(:contact, :with_email, account: account)
    hidden_contact = create(:contact, :with_email, account: account)
    originating_conversation = create(
      :conversation,
      account: account,
      contact: contact,
      inbox: allowed_inbox,
      assignee: agent
    )
    hidden_conversation = create(:conversation, account: account, contact: hidden_contact, inbox: blocked_inbox)
    deal = create(
      :crm_deal,
      account: account,
      pipeline: pipeline,
      stage: stage,
      company: create(:company, account: account),
      originating_conversation: originating_conversation
    )
    create(:crm_deal_contact, account: account, deal: deal, contact: contact, primary: true)
    create(:crm_deal_contact, account: account, deal: deal, contact: hidden_contact)
    create(:crm_comment, account: account, commentable: deal, user: administrator, body: 'Left voicemail')
    create(:crm_event, account: account, eventable: deal, actor: administrator, event_type: 'deal_follow_up_scheduled')

    get "#{deal_path}/#{deal.id}/timeline",
        headers: agent.create_new_auth_token,
        as: :json

    expect(response).to have_http_status(:ok)

    payload = response.parsed_body.fetch('payload')
    item_types = payload.map { |item| item['item_type'] }
    conversation_ids = payload
                       .select { |item| item['item_type'] == 'conversation' }
                       .map { |item| item.dig('payload', 'id') }

    expect(item_types).to include('event', 'comment', 'conversation')
    expect(conversation_ids).to include(originating_conversation.id)
    expect(conversation_ids).not_to include(hidden_conversation.id)
  end
end
