require 'rails_helper'

RSpec.describe BulkActions::SelectionSnapshot do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }

  before { create(:inbox_member, inbox: inbox, user: user) }

  def create_snapshot(resource_type: 'Conversation', filters: {})
    described_class.new(
      account: account,
      user: user,
      resource_type: resource_type,
      filters: filters
    ).perform
  end

  def insert_open_conversations(count, first_display_id: 1)
    timestamp = Time.current
    Conversation.insert_all!(
      (first_display_id...(first_display_id + count)).map do |display_id|
        {
          account_id: account.id,
          inbox_id: inbox.id,
          display_id: display_id,
          status: Conversation.statuses.fetch('open'),
          created_at: timestamp,
          updated_at: timestamp,
          last_activity_at: timestamp,
          uuid: SecureRandom.uuid
        }
      end
    )
  end

  it 'selects matching conversations beyond one page without loading card content' do
    count = ConversationFinder::RESULTS_PER_PAGE + 7
    insert_open_conversations(count)

    selection = create_snapshot(filters: { inbox_id: inbox.id, status: 'all' })

    expect(selection.count).to eq(count)
    expect(selection.ids.size).to eq(count)
    expect(selection.record_ids.size).to eq(count)
    expect(selection.to_h).not_to have_key(:record_ids)
    expect(selection.inbox_ids).to eq([inbox.id])
    expect(selection.inbox_ids_by_id.keys.size).to eq(count)
  end

  it 'selects matching communication threads beyond one page and returns all accessible inboxes' do
    account.enable_features!('communication_threads')
    threads = 0.upto(CommunicationThreadFinder::RESULTS_PER_PAGE + 2).map do
      contact = create(:contact, account: account)
      thread = create(:communication_thread, account: account, contact: contact)
      conversation = create(:conversation, account: account, inbox: inbox, contact: contact, status: :open)
      CommunicationThreadConversation.where(account_id: account.id, conversation_id: conversation.id).delete_all
      conversation.association(:communication_thread_conversation).reset
      conversation.association(:communication_thread).reset
      create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
      thread
    end
    second_inbox = create(:inbox, account: account)
    second_contact_inbox = create(
      :contact_inbox,
      contact: threads.first.contact,
      inbox: second_inbox
    )
    second_conversation = create(
      :conversation,
      account: account,
      inbox: second_inbox,
      contact: threads.first.contact,
      contact_inbox: second_contact_inbox,
      status: :open
    )
    CommunicationThreadConversation.where(
      account_id: account.id,
      conversation_id: second_conversation.id
    ).delete_all
    second_conversation.association(:communication_thread_conversation).reset
    second_conversation.association(:communication_thread).reset
    create(
      :communication_thread_conversation,
      communication_thread: threads.first,
      conversation: second_conversation
    )
    create(:inbox_member, inbox: second_inbox, user: user)

    selection = create_snapshot(
      resource_type: 'CommunicationThread',
      filters: { inbox_id: inbox.id, status: 'all' }
    )

    expect(selection.ids.size).to eq(threads.size)
    expect(selection.record_ids).to match_array(threads.map(&:id))
    expect(selection.inbox_ids).to match_array([inbox.id, second_inbox.id])
    expect(selection.inbox_ids_by_id.keys).to match_array(threads.map { |thread| thread.display_id.to_s })
    expect(selection.inbox_ids_by_id.fetch(threads.first.display_id.to_s)).to match_array([inbox.id, second_inbox.id])
  end

  it 'applies saved advanced filters together with CRM, appointment, unread, label, and team contexts' do
    team = create(:team, account: account)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    other_stage = create(:crm_stage, account: account, pipeline: pipeline)

    matching = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :pending,
      agent_last_seen_at: 1.hour.ago
    )
    other_stage_conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :pending,
      agent_last_seen_at: 1.hour.ago
    )
    other_appointment_conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :pending,
      agent_last_seen_at: 1.hour.ago
    )
    without_label = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :pending,
      agent_last_seen_at: 1.hour.ago
    )
    without_team = create(
      :conversation,
      account: account,
      inbox: inbox,
      status: :pending,
      agent_last_seen_at: 1.hour.ago
    )
    read_conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :pending,
      agent_last_seen_at: 1.minute.ago
    )

    [matching, other_stage_conversation, other_appointment_conversation, without_label, without_team, read_conversation].each do |conversation|
      create(:message, account: account, conversation: conversation, inbox: inbox, created_at: 10.minutes.ago)
    end
    [matching, other_stage_conversation, other_appointment_conversation, without_team, read_conversation].each do |conversation|
      conversation.add_labels(['vip'])
    end
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: matching)
    create(:crm_deal, account: account, pipeline: pipeline, stage: other_stage, originating_conversation: other_stage_conversation)
    create(:crm_deal, account: account, pipeline: pipeline, stage: stage, originating_conversation: other_appointment_conversation)
    create(:scheduling_appointment, account: account, contact: matching.contact, conversation: matching, status: 'confirmed')
    create(:scheduling_appointment, account: account, contact: other_appointment_conversation.contact, conversation: other_appointment_conversation, status: 'scheduled')

    selection = create_snapshot(
      filters: {
        mode: 'advanced',
        # Saved filters are camel-cased at the list boundary; the server must
        # preserve their query and contextual filters when taking the snapshot.
        queryData: {
          payload: [
            {
              attribute_key: 'status',
              filter_operator: 'equal_to',
              values: ['pending'],
              query_operator: nil
            }
          ]
        },
        crmPipelineId: pipeline.id,
        crmStageId: stage.id,
        appointmentStatus: 'confirmed',
        labelsScope: 'any',
        teamScope: 'any',
        unread: true
      }
    )

    expect(selection.ids).to contain_exactly(matching.display_id)
  end

  it 'accepts exactly 1000 matches and rejects 1001 without truncating' do
    insert_open_conversations(described_class::MAX_SELECTION_SIZE)
    selection = create_snapshot(filters: { inbox_id: inbox.id, status: 'all' })
    expect(selection.count).to eq(described_class::MAX_SELECTION_SIZE)

    insert_open_conversations(1, first_display_id: described_class::MAX_SELECTION_SIZE + 1)
    expect do
      create_snapshot(filters: { inbox_id: inbox.id, status: 'all' })
    end.to raise_error(described_class::TooManyRecords) { |error|
      expect(error.limit).to eq(described_class::MAX_SELECTION_SIZE)
    }
  end

  it 'rejects an empty matching scope' do
    expect do
      create_snapshot(filters: { inbox_id: inbox.id, status: 'resolved' })
    end.to raise_error(described_class::EmptySelection)
  end

  it 'binds the signed snapshot to its account, user, and resource type' do
    create(:conversation, account: account, inbox: inbox)
    selection = create_snapshot(filters: { inbox_id: inbox.id, status: 'all' })

    expect(described_class.verify!(selection.token, account: account, user: user, resource_type: 'Conversation').count).to eq(1)
    expect do
      described_class.verify!(selection.token, account: create(:account), user: user, resource_type: 'Conversation')
    end.to raise_error(described_class::InvalidSelection)
    expect do
      described_class.verify!(selection.token, account: account, user: create(:user, account: account), resource_type: 'Conversation')
    end.to raise_error(described_class::InvalidSelection)
    expect do
      described_class.verify!(selection.token, account: account, user: user, resource_type: 'CommunicationThread')
    end.to raise_error(described_class::InvalidSelection)
  end

  it 'rejects tampered, expired, and duplicate-id claims' do
    create(:conversation, account: account, inbox: inbox)
    selection = create_snapshot(filters: { inbox_id: inbox.id, status: 'all' })
    tampered_token = "#{selection.token[0..-2]}#{selection.token[-1] == 'a' ? 'b' : 'a'}"
    expect do
      described_class.verify!(tampered_token, account: account, user: user, resource_type: 'Conversation')
    end.to raise_error(described_class::InvalidSelection)

    travel 6.minutes do
      expect do
        described_class.verify!(selection.token, account: account, user: user, resource_type: 'Conversation')
      end.to raise_error(described_class::InvalidSelection)
    end

    duplicate_token = described_class.verifier.generate(
      {
        version: 1,
        account_id: account.id,
        user_id: user.id,
        resource_type: 'Conversation',
        ids: [selection.ids.first, selection.ids.first],
        record_ids: [selection.record_ids.first, selection.record_ids.first],
        count: 2
      },
      expires_in: described_class::TOKEN_TTL,
      purpose: described_class::PURPOSE
    )
    expect do
      described_class.verify!(duplicate_token, account: account, user: user, resource_type: 'Conversation')
    end.to raise_error(described_class::InvalidSelection)
  end

  it 'rejects local search values rather than treating them as server filters' do
    insert_open_conversations(2)

    expect do
      create_snapshot(filters: { mode: 'basic', status: 'all', q: 'loaded message text' })
    end.to raise_error(described_class::InvalidFilters)

    expect do
      create_snapshot(filters: { mode: 'basic', status: 'all', query: 'loaded message text' })
    end.to raise_error(described_class::InvalidFilters)
  end
end
