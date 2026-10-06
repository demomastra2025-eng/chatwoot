require 'rails_helper'

RSpec.describe BulkActions::SelectionSnapshot do
  let(:account) { create(:account) }
  let(:advanced_filter_fixture) do
    team = create(:team, account: account)
    pipeline = create(:crm_pipeline, account: account)
    stage = create(:crm_stage, account: account, pipeline: pipeline)
    other_stage = create(:crm_stage, account: account, pipeline: pipeline)

    matching = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :open,
      agent_last_seen_at: 1.hour.ago
    )
    other_stage_conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :open,
      agent_last_seen_at: 1.hour.ago
    )
    other_appointment_conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :open,
      agent_last_seen_at: 1.hour.ago
    )
    without_label = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :open,
      agent_last_seen_at: 1.hour.ago
    )
    without_team = create(
      :conversation,
      account: account,
      inbox: inbox,
      status: :open,
      agent_last_seen_at: 1.hour.ago
    )
    read_conversation = create(
      :conversation,
      account: account,
      inbox: inbox,
      team: team,
      status: :open,
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
    create(:scheduling_appointment, account: account, contact: other_appointment_conversation.contact, conversation: other_appointment_conversation,
                                    status: 'scheduled')

    [matching, pipeline, stage]
  end
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

  def create_thread_in(target_inbox)
    contact = create(:contact, account: account)
    thread = create(:communication_thread, account: account, contact: contact)
    conversation = create(:conversation, account: account, inbox: target_inbox, contact: contact, status: :open)
    CommunicationThreadConversation.where(account_id: account.id, conversation_id: conversation.id).delete_all
    conversation.association(:communication_thread_conversation).reset
    conversation.association(:communication_thread).reset
    create(:communication_thread_conversation, communication_thread: thread, conversation: conversation)
    thread
  end

  def insert_open_conversations(count, first_display_id: 1)
    count.times do |offset|
      create(:conversation, account: account, inbox: inbox, status: :open, display_id: first_display_id + offset)
    end
  end

  it 'selects matching conversations beyond one page without loading card content' do
    count = ENV.fetch('CONVERSATION_RESULTS_PER_PAGE', '25').to_i + 7
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
    expect(selection.inbox_ids).to contain_exactly(inbox.id, second_inbox.id)
    expect(selection.inbox_ids_by_id.keys).to match_array(threads.map { |thread| thread.display_id.to_s })
    expect(selection.inbox_ids_by_id.fetch(threads.first.display_id.to_s)).to contain_exactly(inbox.id, second_inbox.id)
  end

  it 'applies saved advanced filters together with CRM, appointment, unread, label, and team contexts' do
    matching, pipeline, stage = advanced_filter_fixture
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
              values: ['open'],
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

  it 'never includes conversations of another account or of inboxes the user cannot access' do
    visible = create(:conversation, account: account, inbox: inbox)
    create(:conversation, account: account, inbox: create(:inbox, account: account))
    create(:conversation, account: create(:account))

    selection = create_snapshot(filters: { status: 'all' })

    expect(selection.ids).to eq([visible.display_id])
    expect(selection.record_ids).to eq([visible.id])
    expect(selection.inbox_ids_by_id).to eq(visible.display_id.to_s => [inbox.id])
  end

  it 'excludes communication threads whose channels the user cannot access' do
    account.enable_features!('communication_threads')
    visible = create_thread_in(inbox)
    create_thread_in(create(:inbox, account: account))

    selection = create_snapshot(resource_type: 'CommunicationThread', filters: { status: 'all' })

    expect(selection.record_ids).to eq([visible.id])
    expect(selection.inbox_ids_by_id).to eq(visible.display_id.to_s => [inbox.id])
  end

  it 'allows a bounded snapshot of 10,000 conversations' do
    expect(described_class::MAX_SELECTION_SIZE).to eq(10_000)
  end

  it 'accepts the limit and rejects one more match without truncating' do
    stub_const('BulkActions::SelectionSnapshot::MAX_SELECTION_SIZE', 30)
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

  it 'selects all server search matches and ignores list filters' do
    matching = create(:conversation, account: account, inbox: inbox, status: :open)
    create(:message, conversation: matching, account: account, content: 'snapshot search needle')
    create(:conversation, account: account, inbox: inbox, status: :resolved)

    selection = create_snapshot(filters: {
                                  mode: 'basic', status: 'resolved', inbox_id: -1, q: 'snapshot search needle'
                                })

    expect(selection.ids).to eq([matching.display_id])
  end

  it 'uses the same capped search set and excludes inaccessible inboxes and accounts' do
    stub_const('Search::ConversationLookup::CONVERSATION_LIMIT', 1)
    contact = create(:contact, account: account, name: 'Пациент Проверка')
    first = create(:conversation, account: account, inbox: inbox, contact: contact, status: :open)
    second = create(:conversation, account: account, inbox: inbox, contact: contact, status: :resolved)
    create(:conversation, account: account, inbox: create(:inbox, account: account), contact: contact)
    foreign_account = create(:account)
    create(:conversation, account: foreign_account, inbox: create(:inbox, account: foreign_account),
                          contact: create(:contact, account: foreign_account, name: 'Пациент Проверка'))

    search = Conversations::ListSearchService.new(user: user, account: account, params: { q: 'Пациент Проверка' }).perform
    selection = create_snapshot(filters: { mode: 'basic', q: 'Пациент Проверка' })

    expect(search[:meta]).to include(total_count: 1, capped: true)
    expect(selection.record_ids).to eq(search[:conversations].map(&:id))
    expect(selection.record_ids).to all(be_in([first.id, second.id]))
    expect(selection.count).to eq(1)
  end

  it 'uses the thread list search scope for a thread snapshot' do
    account.enable_features!('communication_threads')
    visible = create_thread_in(inbox)
    hidden = create_thread_in(create(:inbox, account: account))
    visible.contact.update!(name: 'Пациент Проверка')
    hidden.contact.update!(name: 'Пациент Проверка')

    selection = create_snapshot(resource_type: 'CommunicationThread', filters: { mode: 'basic', q: 'Пациент Проверка' })

    expect(selection.record_ids).to eq([visible.id])
  end

  it 'keeps custom-role restrictions in the search snapshot' do
    role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
    user.account_users.find_by(account: account).update!(custom_role: role)
    visible = create(:conversation, account: account, inbox: inbox, assignee: user)
    hidden = create(:conversation, account: account, inbox: inbox)
    [visible, hidden].each do |conversation|
      create(:message, account: account, inbox: inbox, conversation: conversation,
                       message_type: :incoming, content: 'Проверка доступа к выбору')
    end

    selection = create_snapshot(filters: { mode: 'basic', q: 'Проверка доступа к выбору' })

    expect(selection.record_ids).to eq([visible.id])
  end

  it 'rejects an unsupported search key instead of widening the selection' do
    expect do
      create_snapshot(filters: { mode: 'basic', query: 'needle' })
    end.to raise_error(described_class::InvalidFilters)
  end
end
