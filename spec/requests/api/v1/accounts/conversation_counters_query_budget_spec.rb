# frozen_string_literal: true

require 'rails_helper'

# The dialog list and the counters of the sidebar are read all day by every open dashboard, so the number of SQL
# queries per request is capped. Every request is made twice and only the second one is counted, so one-off
# lookups (feature flags, caches) do not count. About five of the queries are the shared authentication and
# account lookups of any API request.
#
# Measured on this data set before the counters were lightened (administrator / agent):
#   conversations 69 / 64, page 2 23, meta 22, sidebar_unread_counts 13,
#   communication_threads 60 / 58, meta 18, sidebar_unread_counts 15.
RSpec.describe 'Conversation counters query budget', type: :request do
  let(:account) { create(:account) }
  let(:administrator) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:team) { create(:team, account: account) }
  let(:base_path) { "/api/v1/accounts/#{account.id}" }
  let(:open_filters) { { status: 'open', assignee_type: 'all' } }
  let(:tokens) { {} }

  before do
    account.enable_features!('communication_threads', 'crm_deals', 'scheduling')
    inboxes = Array.new(3) { create(:inbox, account: account, enable_auto_assignment: false) }
    inboxes.first(2).each { |inbox| create(:inbox_member, user: agent, inbox: inbox) }
    inboxes.each { |inbox| create(:inbox_member, user: administrator, inbox: inbox) }
    create_unread_conversations(inboxes)
  end

  # Six open unread conversations carry the team; one agent inbox out of three is hidden from the agent.
  def team_unread_count
    role == :administrator ? 6 : 4
  end

  def create_unread_conversations(inboxes)
    12.times do |index|
      conversation = create(
        :conversation,
        account: account,
        inbox: inboxes[index % 3],
        assignee: [agent, administrator, nil][index % 3],
        team: [team, nil][index % 2],
        status: %w[open pending][index % 2],
        agent_last_seen_at: 1.day.ago
      )
      conversation.update_labels('vip') if index.even?
      create(:message, account: account, conversation: conversation, inbox: conversation.inbox,
                       message_type: :incoming, created_at: 1.hour.ago, skip_runtime_events: true)
      conversation.reload.refresh_communication_thread!
    end
  end

  # One token per user, reused for every request (as the other request specs do).
  def auth_headers(user)
    tokens[user.id] ||= user.create_new_auth_token
  end

  def queries_for(user, path, params = {})
    get path, headers: auth_headers(user), params: params, as: :json
    queries = sql_queries_during { get path, headers: auth_headers(user), params: params, as: :json }
    expect(response).to have_http_status(:ok)
    queries
  end

  %i[administrator agent].each do |role_name|
    context "when requested by an #{role_name}" do
      let(:role) { role_name }
      let(:user) { public_send(role_name) }

      it 'keeps GET conversations within its budget and skips the counters after the first page' do
        first_page = queries_for(user, "#{base_path}/conversations", open_filters)
        first_page_meta = response.parsed_body.dig('data', 'meta')
        later_page = queries_for(user, "#{base_path}/conversations", open_filters.merge(page: 2, include_meta: false))

        expect(first_page.size).to be <= 62
        expect(later_page.size).to be <= 11
        expect(later_page.size).to be < first_page.size
        expect(first_page_meta.keys).to include('all_count', 'mine_count', 'unread_counts')
        expect(response.parsed_body.dig('data', 'meta')).to be_blank
      end

      it 'keeps GET conversations/meta within its budget' do
        queries = queries_for(user, "#{base_path}/conversations/meta", open_filters)

        expect(queries.size).to be <= 13
        expect(response.parsed_body.dig('meta', 'unread_counts')).to include('teams' => { team.id.to_s => team_unread_count })
      end

      it 'keeps GET conversations/sidebar_unread_counts within its budget' do
        queries = queries_for(user, "#{base_path}/conversations/sidebar_unread_counts")

        expect(queries.size).to be <= 8
        expect(response.parsed_body.fetch('counts')).to include('teams' => { team.id.to_s => team_unread_count })
      end

      it 'keeps GET communication_threads within its budget with and without the counters' do
        with_meta = queries_for(user, "#{base_path}/communication_threads", open_filters)
        without_meta = queries_for(user, "#{base_path}/communication_threads", open_filters.merge(include_meta: false))

        expect(with_meta.size).to be <= 57
        expect(without_meta.size).to be <= 53
        expect(without_meta.size).to be < with_meta.size
        expect(response.parsed_body.dig('data', 'meta')).to be_blank
      end

      it 'keeps GET communication_threads/meta within its budget' do
        queries = queries_for(user, "#{base_path}/communication_threads/meta", open_filters)

        expect(queries.size).to be <= 13
        expect(queries.grep(/communication_threads"\."id" IN \(\d+, /)).to be_empty
      end

      it 'keeps GET communication_threads/sidebar_unread_counts within its budget' do
        queries = queries_for(user, "#{base_path}/communication_threads/sidebar_unread_counts", open_filters)

        expect(queries.size).to be <= 10
        expect(response.parsed_body.fetch('counts').keys).to contain_exactly(
          'all', 'statuses', 'inboxes', 'teams', 'labels', 'pipelines', 'stages', 'appointment_statuses'
        )
      end
    end
  end
end
