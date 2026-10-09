# frozen_string_literal: true

require 'rails_helper'

# The unread base of the thread counts is a subquery now (it used to be a materialised list of thread ids).
# The counts must stay equal to a per-thread count done in Ruby on randomised data, for an administrator and
# for an agent whose inbox access is restricted.
RSpec.describe CommunicationThreadFinder do
  let!(:account) { create(:account) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:other_agent) { create(:user, account: account, role: :agent) }
  let!(:first_inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:second_inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:restricted_inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let!(:team) { create(:team, account: account) }
  let!(:other_team) { create(:team, account: account) }
  let(:random) { Random.new(20_261_006) }
  let(:rows) { [] }

  before do
    Current.account = account
    restricted_inbox.inbox_members.where(user: [agent, admin]).destroy_all
    create(:inbox_member, user: agent, inbox: first_inbox)
    create(:inbox_member, user: agent, inbox: second_inbox)
    assignees = [agent, other_agent, admin, nil, nil]
    teams = [team, other_team, nil]
    inboxes = [first_inbox, second_inbox, restricted_inbox]

    30.times do
      target_inbox = inboxes[random.rand(inboxes.size)]
      unread = random.rand(3)
      contact = create(:contact, account: account)
      conversation = create(:conversation, account: account, inbox: target_inbox, contact: contact)
      thread = create(:communication_thread, account: account, contact: contact,
                                             assignee: assignees[random.rand(assignees.size)],
                                             team: teams[random.rand(teams.size)])
      create(:communication_thread_conversation, account: account, communication_thread: thread,
                                                 conversation: conversation, inbox: target_inbox,
                                                 contact_inbox: conversation.contact_inbox)
      if unread.positive?
        create(:message, account: account, conversation: conversation, inbox: target_inbox, message_type: :incoming,
                         created_at: 10.minutes.ago)
        conversation.update!(agent_last_seen_at: 1.hour.ago)
      end
      rows << { thread: thread.reload, inbox_id: target_inbox.id, unread: unread.positive? }
    end
  end

  def visible_rows(user)
    return rows if user == admin

    rows.select { |row| [first_inbox.id, second_inbox.id].include?(row[:inbox_id]) }
  end

  def assignee_counts(items, user)
    threads = items.pluck(:thread)
    {
      mine_count: threads.count { |thread| thread.assignee_id == user.id },
      assigned_count: threads.count { |thread| thread.assignee_id.present? },
      unassigned_count: threads.count { |thread| thread.assignee_id.nil? },
      all_count: threads.size
    }
  end

  [:admin, :agent].each do |role|
    describe "as #{role}" do
      let(:user) { public_send(role) }

      it 'returns the same ownership and unread counts as a per-thread count' do
        counts = described_class.new(user, status: 'all', assignee_type: 'all').perform_meta_only[:count]
        visible = visible_rows(user)
        unread = assignee_counts(visible.select { |row| row[:unread] }, user)

        expect(counts.slice(:mine_count, :assigned_count, :unassigned_count, :all_count))
          .to eq(assignee_counts(visible, user))
        expect(counts[:assignee_counts]).to eq(assignee_counts(visible, user))
        expect(
          mine_unread_count: counts[:mine_unread_count],
          assigned_unread_count: counts[:assigned_unread_count],
          unassigned_unread_count: counts[:unassigned_unread_count],
          all_unread_count: counts[:all_unread_count]
        ).to eq(
          mine_unread_count: unread[:mine_count],
          assigned_unread_count: unread[:assigned_count],
          unassigned_unread_count: unread[:unassigned_count],
          all_unread_count: unread[:all_count]
        )
      end

      it 'counts the unread threads of the team badge with the active filters' do
        counts = described_class.new(user, status: 'all', assignee_type: 'me').perform_meta_only[:count]
        expected = visible_rows(user)
                   .select { |row| row[:unread] && row[:thread].assignee_id == user.id && row[:thread].team_id.present? }
                   .group_by { |row| row[:thread].team_id.to_s }
                   .transform_values(&:size)

        expect(counts.dig(:unread_counts, :teams)).to eq(expected)
      end

      it 'keeps the unread-only list and its counts equal to the unread threads' do
        result = described_class.new(user, status: 'all', assignee_type: 'all', unread: 'true').perform
        unread = visible_rows(user).select { |row| row[:unread] }
        counts = result[:count]

        expect(result[:communication_threads].map(&:id)).to match_array(unread.map { |row| row[:thread].id })
        expect(counts.slice(:mine_count, :assigned_count, :unassigned_count, :all_count))
          .to eq(assignee_counts(unread, user))
        expect(counts[:all_unread_count]).to eq(counts[:all_count])
        expect(counts[:mine_unread_count]).to eq(counts[:mine_count])
        expect(counts[:unassigned_unread_count]).to eq(counts[:unassigned_count])
      end
    end
  end

  it 'does not load a list of thread ids to count the unread threads' do
    queries = sql_queries_during do
      described_class.new(admin, status: 'all', assignee_type: 'all').perform_meta_only
    end

    expect(queries.size).to be <= 7
    expect(queries.grep(/communication_threads\.id IN \(\s*\d+\s*,/)).to be_empty
  end
end
