# frozen_string_literal: true

require 'rails_helper'

# The assignee counts of the finder come from FILTER aggregates. They must equal the plain per-record counts
# (here done in Ruby on a randomised data set), for an administrator and for an agent with restricted inboxes,
# with and without filters.
describe ConversationFinder do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:other_agent) { create(:user, account: account, role: :agent) }
  let!(:first_inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:second_inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:restricted_inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:team) { create(:team, account: account) }
  let!(:other_team) { create(:team, account: account) }
  let(:random) { Random.new(20_261_004) }
  let(:records) { {} }

  before do
    Current.account = account
    [agent, other_agent].each do |member|
      create(:inbox_member, user: member, inbox: first_inbox)
      create(:inbox_member, user: member, inbox: second_inbox)
    end
    assignees = [agent, other_agent, admin, nil, nil]
    teams = [team, other_team, nil]
    label_sets = [[], [], %w[vip], %w[lead], %w[vip lead]]
    statuses = %w[open open open pending resolved]
    inboxes = [first_inbox, second_inbox, restricted_inbox]

    60.times do
      conversation = create(
        :conversation,
        account: account,
        inbox: inboxes[random.rand(inboxes.size)],
        assignee: assignees[random.rand(assignees.size)],
        team: teams[random.rand(teams.size)],
        status: statuses[random.rand(statuses.size)]
      )
      labels = label_sets[random.rand(label_sets.size)]
      conversation.update_labels(labels) if labels.present?
      records[conversation.id] = { conversation: conversation.reload, labels: labels }
    end
  end

  def accessible_for(user)
    items = records.values
    return items if user == admin

    items.select { |item| [first_inbox.id, second_inbox.id].include?(item[:conversation].inbox_id) }
  end

  def expected_counts(items, user)
    conversations = items.pluck(:conversation)
    {
      mine_count: conversations.count { |conversation| conversation.assignee_id == user.id },
      assigned_count: conversations.count { |conversation| conversation.assignee_id.present? },
      unassigned_count: conversations.count { |conversation| conversation.assignee_id.nil? },
      all_count: conversations.size
    }
  end

  def apply_filters(items, params)
    items = filter_by_status(items, params[:status] || 'open')
    items = filter_by_inbox_and_team(items, params)
    filter_by_labels(items, params)
  end

  def filter_by_status(items, status)
    return items if status == 'all'

    items.select { |item| item[:conversation].status == status }
  end

  def filter_by_inbox_and_team(items, params)
    items = items.select { |item| item[:conversation].inbox_id == params[:inbox_id] } if params[:inbox_id]
    items = items.select { |item| item[:conversation].team_id == params[:team_id] } if params[:team_id]
    items = items.select { |item| item[:conversation].team_id.present? } if params[:team_scope] == 'any'
    items
  end

  def filter_by_labels(items, params)
    items = items.select { |item| item[:labels].intersect?(params[:labels]) } if params[:labels]
    items = items.select { |item| item[:labels].any? } if params[:labels_scope] == 'any'
    items
  end

  filter_sets = [
    {},
    { status: 'all' },
    { status: 'pending', assignee_type: 'me' },
    { status: 'open', assignee_type: 'unassigned' },
    { status: 'all', assignee_type: 'assigned' },
    { status: 'open', inbox_id: :first_inbox },
    { status: 'all', team_id: :team },
    { status: 'resolved', team_scope: 'any' },
    { status: 'all', labels: %w[vip] },
    { status: 'open', labels: %w[vip lead] },
    { status: 'all', labels_scope: 'any' },
    { status: 'open', inbox_id: :second_inbox, team_id: :other_team, labels_scope: 'any' }
  ]

  %i[admin agent].each do |role|
    describe "as #{role}" do
      let(:user) { public_send(role) }

      filter_sets.each do |filter_set|
        it "returns the same assignee counts as a per-record count with #{filter_set.inspect}" do
          params = filter_set.transform_values { |value| value.is_a?(Symbol) ? public_send(value).id : value }
          visible = accessible_for(user)

          counts = described_class.new(user, params).perform[:count]

          expect(counts.slice(:mine_count, :assigned_count, :unassigned_count, :all_count))
            .to eq(expected_counts(apply_filters(visible, params), user))
          expect(counts[:assignee_counts]).to eq(expected_counts(visible, user))
        end
      end

      it 'returns the same counts from the meta-only call' do
        params = { status: 'open' }

        counts = described_class.new(user, params).perform_meta_only[:count]

        expect(counts[:all_count]).to eq(apply_filters(accessible_for(user), params).size)
      end
    end
  end

  describe 'filter service counts' do
    it 'matches the per-record counts for the advanced filter result' do
      [admin, agent].each do |user|
        payload = [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil,
                     custom_attribute_type: '' }.with_indifferent_access]

        counts = Conversations::FilterService.new({ payload: payload, page: 1 }, user, account).perform[:count]

        expect(counts.slice(:mine_count, :assigned_count, :unassigned_count, :all_count))
          .to eq(expected_counts(apply_filters(accessible_for(user), status: 'open'), user))
      end
    end

    it 'skips the counts when include_meta is false' do
      payload = [{ attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: nil,
                   custom_attribute_type: '' }.with_indifferent_access]

      result = Conversations::FilterService.new({ payload: payload, page: 2, include_meta: false }, admin, account).perform

      expect(result[:count]).to eq({})
    end
  end
end
