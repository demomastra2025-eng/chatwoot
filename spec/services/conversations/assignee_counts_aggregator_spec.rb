# frozen_string_literal: true

require 'rails_helper'

# The aggregator replaces three separate COUNT queries. These specs compare it with those plain counts
# (and with a count done in Ruby) on randomised data, for a plain, a joined DISTINCT and a paginated relation.
RSpec.describe Conversations::AssigneeCountsAggregator do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:other_agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:random) { Random.new(20_261_005) }
  let(:labels_join) do
    'INNER JOIN taggings any_label ON any_label.taggable_id = conversations.id ' \
      "AND any_label.taggable_type = 'Conversation' AND any_label.context = 'labels'"
  end

  def plain_counts(relation, user)
    {
      all_count: relation.count,
      mine_count: relation.assigned_to(user).count,
      unassigned_count: relation.unassigned.count
    }
  end

  before do
    create(:inbox_member, user: agent, inbox: inbox)
    create(:inbox_member, user: other_agent, inbox: inbox)
    assignees = [agent, other_agent, nil]
    statuses = Conversation.statuses.keys
    40.times do |index|
      conversation = create(
        :conversation,
        account: account,
        inbox: inbox,
        assignee: assignees[random.rand(assignees.size)],
        status: statuses[random.rand(statuses.size)]
      )
      conversation.update_labels(%w[vip lead]) if index < 6
      conversation.update_labels(%w[vip]) if (6..12).cover?(index)
    end
  end

  it 'matches three separate counts on a plain relation' do
    relation = account.conversations.where(status: %w[open pending])

    expect(described_class.new(relation, user_id: agent.id).perform).to eq(plain_counts(relation, agent))
  end

  it 'matches three separate counts for another user and for a relation with an ordering and includes' do
    relation = account.conversations.includes(:inbox, :contact).order(created_at: :desc)

    expect(described_class.new(relation, user_id: other_agent.id).perform).to eq(plain_counts(relation, other_agent))
  end

  it 'counts every record once for a joined DISTINCT relation with several labels' do
    joined = account.conversations.joins(labels_join)
    relation = joined.distinct

    expect(joined.count).to be > relation.count
    expect(described_class.new(relation, user_id: agent.id).perform).to eq(plain_counts(relation, agent))
  end

  it 'matches the counts of a Ruby loop' do
    conversations = account.conversations.to_a

    expect(described_class.new(account.conversations, user_id: agent.id).perform).to eq(
      all_count: conversations.size,
      mine_count: conversations.count { |conversation| conversation.assignee_id == agent.id },
      unassigned_count: conversations.count { |conversation| conversation.assignee_id.nil? }
    )
  end

  it 'falls back to the plain counts for a paginated relation' do
    relation = account.conversations.order(:id).page(1).per(7)

    expect(described_class.new(relation, user_id: agent.id).perform).to eq(plain_counts(relation, agent))
  end

  it 'falls back to the plain counts when the relation eager loads a joined search' do
    create(:message, account: account, conversation: account.conversations.first, message_type: :incoming)
    relation = account.conversations.joins(:messages).where(messages: { message_type: 0 }).includes(:messages)

    expect(described_class.new(relation, user_id: agent.id).perform).to eq(plain_counts(relation, agent))
  end

  it 'counts communication threads the same way' do
    assignees = [agent, other_agent, nil]
    threads = Array.new(15) do
      create(
        :communication_thread,
        account: account,
        contact: create(:contact, account: account),
        assignee: assignees[random.rand(assignees.size)]
      )
    end
    relation = CommunicationThread.where(account_id: account.id, id: threads.map(&:id))

    expect(described_class.new(relation, user_id: agent.id).perform).to eq(
      all_count: 15,
      mine_count: threads.count { |thread| thread.assignee_id == agent.id },
      unassigned_count: threads.count { |thread| thread.assignee_id.nil? }
    )
  end

  it 'uses a single query for an aggregatable relation' do
    relation = account.conversations.where(status: 'open')
    counts = nil

    queries = sql_queries_during { counts = described_class.new(relation, user_id: agent.id).perform }

    expect(counts[:all_count]).to eq(relation.count)
    expect(queries.size).to eq(1)
  end
end
