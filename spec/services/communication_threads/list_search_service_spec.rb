require 'rails_helper'

# The search box of the conversation list in communication-thread mode (derives from e/search commits c0c6939ef,
# ace4be3c0 and the P1 fix 8b6fc90ef): the permission scope decides what leads to a thread.
RSpec.describe CommunicationThreads::ListSearchService do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:params) { { q: 'Иванов' } }

  let!(:ivan) { create(:contact, account: account, name: 'Иван Иванов', phone_number: '+77072817060') }
  # Resolved, assigned to a colleague: neither "Open" nor "Mine".
  let!(:resolved_conversation) do
    create(:conversation, account: account, inbox: inbox, contact: ivan, status: :resolved, assignee: colleague)
  end

  before do
    account.enable_features!('communication_threads')
    create(:inbox_member, user: agent, inbox: inbox)
    create(:inbox_member, user: colleague, inbox: inbox)
  end

  def thread_of(conversation)
    conversation.reload.refresh_communication_thread!
    conversation.reload.communication_thread
  end

  def search(search_params = params, user: agent)
    described_class.new(user: user, account: account, params: ActionController::Parameters.new(search_params)).perform
  end

  def ids_for(query, user: agent)
    found_ids({ q: query }, user: user)
  end

  def found_ids(search_params = params, user: agent)
    search(search_params, user: user)[:communication_threads].map(&:id)
  end

  def message_in(conversation, content, **attributes)
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :incoming, content: content,
                     **attributes)
  end

  describe 'list filters' do
    it 'searches threads whatever the status or assignee of their conversations' do
      thread = thread_of(resolved_conversation)
      # a status the list filter would hide
      thread.update_columns(status: CommunicationThread.statuses[:resolved]) # rubocop:disable Rails/SkipsModelValidations

      expect(found_ids).to eq([thread.id])
    end

    it 'ignores the status, assignee, inbox, team, label, unread and CRM filters of the list' do
      thread = thread_of(resolved_conversation)
      team = create(:team, account: account)
      filters = {
        status: 'open', assignee_type: 'me', inbox_id: other_inbox.id, team_id: team.id, team_scope: 'any', labels: ['vip'],
        labels_scope: 'any', unread: 'true', crm_pipeline_id: 1, crm_stage_id: 2, appointment_status: 'confirmed',
        sort_by: 'priority_asc', include_meta: 'false'
      }

      expect(found_ids(params.merge(filters))).to eq([thread.id])
    end
  end

  describe 'what is found' do
    it 'finds a thread by a phone number typed in any format' do
      thread = thread_of(resolved_conversation)

      aggregate_failures do
        ['87072817060', '+77072817060', '7 707 281 70 60', '+7 (707) 281-70-60', '707 281 70 60', '8-707-281-70-60', '2817060',
         "\u200E+7 707 281 70 60\u200F"].each do |query|
          expect(ids_for(query)).to eq([thread.id]), "expected #{query.inspect} to find the thread of the contact"
        end
      end
    end

    it 'finds a thread by the contact name in any word order' do
      thread = thread_of(resolved_conversation)

      expect(ids_for('иванов иван')).to eq([thread.id])
    end

    it 'finds a thread by the text of a message in any of its conversations, exactly as typed' do
      thread = thread_of(resolved_conversation)
      second_inbox_conversation = create(:conversation, account: account, inbox: other_inbox, contact: ivan)
      create(:inbox_member, user: agent, inbox: other_inbox)
      thread_of(second_inbox_conversation)
      message_in(second_inbox_conversation, 'Мы записали вас на приём')

      aggregate_failures do
        expect(ids_for('записали')).to eq([thread.id])
        expect(ids_for('записаться')).to be_empty
      end
    end

    it 'returns a thread once when several conversations and messages match' do
      thread = thread_of(resolved_conversation)
      2.times { |index| message_in(resolved_conversation, "Нужна справка номер #{index}") }

      expect(ids_for('справка')).to eq([thread.id])
    end

    it 'finds a thread by its number and by the number of one of its conversations' do
      thread = thread_of(resolved_conversation)

      aggregate_failures do
        expect(ids_for(thread.display_id.to_s)).to include(thread.id)
        expect(ids_for(resolved_conversation.display_id.to_s)).to include(thread.id)
      end
    end

    it 'finds nothing for a blank query or one that is too short to search' do
      thread_of(resolved_conversation)

      aggregate_failures do
        expect(ids_for('')).to be_empty
        expect(found_ids({})).to be_empty
        expect(ids_for('Ив')).to be_empty
      end
    end

    it 'orders the threads by their latest activity' do
      older_contact = create(:contact, account: account, name: 'Анна Иванова')
      newer_contact = create(:contact, account: account, name: 'Борис Иванов')
      oldest = thread_of(resolved_conversation)
      older = thread_of(create(:conversation, account: account, inbox: inbox, contact: older_contact))
      newer = thread_of(create(:conversation, account: account, inbox: inbox, contact: newer_contact))
      oldest.update_columns(last_activity_at: 5.days.ago) # rubocop:disable Rails/SkipsModelValidations -- fix the order under test
      older.update_columns(last_activity_at: 2.days.ago) # rubocop:disable Rails/SkipsModelValidations -- fix the order under test
      newer.update_columns(last_activity_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations -- fix the order under test

      expect(found_ids).to eq([newer.id, older.id, oldest.id])
    end
  end

  describe 'who may see what' do
    it 'never returns a thread whose conversations are all in inboxes the agent is not a member of' do
      thread_of(resolved_conversation)
      hidden_contact = create(:contact, account: account, name: 'Скрытый Иванов', phone_number: '+77015550000')
      hidden_conversation = create(:conversation, account: account, inbox: other_inbox, contact: hidden_contact)
      hidden_thread = thread_of(hidden_conversation)
      message_in(hidden_conversation, 'Секретная справка')

      aggregate_failures do
        expect(ids_for('Иванов')).not_to include(hidden_thread.id)
        expect(ids_for('8 701 555 00 00')).to be_empty
        expect(ids_for('секретная')).to be_empty
        expect(ids_for(hidden_thread.display_id.to_s)).to be_empty
        expect(ids_for(hidden_conversation.display_id.to_s)).not_to include(hidden_thread.id)
      end
    end

    context 'with a custom role that opens fewer conversations than its inbox holds' do
      let(:hidden_contact) { create(:contact, account: account, name: 'Скрытый Петров', phone_number: '+77015550000') }
      # in an inbox of the agent, but unassigned and without the agent taking part: not for this role
      let!(:hidden) { create(:conversation, account: account, inbox: inbox, contact: hidden_contact) }
      let!(:hidden_thread) { thread_of(hidden) }
      let!(:visible) { create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account), assignee: agent) }
      let!(:visible_thread) { thread_of(visible) }

      before do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
        agent.account_users.find_by(account: account).update!(custom_role: custom_role)
        message_in(hidden, 'Секретная справка про диагноз')
        message_in(visible, 'Нужная справка для вас')
      end

      it 'never returns a thread found only through a conversation the role cannot open: not by text, name, phone or number' do
        aggregate_failures do
          expect(ids_for('справка')).to eq([visible_thread.id])
          expect(ids_for('секретная справка')).to be_empty
          expect(ids_for('Секретный')).to be_empty
          expect(ids_for('Скрытый')).to be_empty
          expect(ids_for('Петров')).to be_empty
          expect(ids_for('8 701 555 00 00')).to be_empty
          expect(ids_for(hidden_thread.display_id.to_s)).to be_empty
          expect(ids_for(hidden.display_id.to_s)).not_to include(hidden_thread.id)
        end
      end

      it 'does not put the contact name or phone of such a thread into the answer' do
        results = search({ q: 'справка' })

        serialized = results[:communication_threads].flat_map { |thread| [thread.contact&.name, thread.contact&.phone_number] }
        expect(serialized).not_to include('Скрытый Петров', '+77015550000')
      end

      it 'does not let the messages of conversations the role cannot open use up the message limit' do
        stub_const('Search::ConversationLookup::MESSAGE_LIMIT', 2)
        3.times { message_in(hidden, 'Нужная справка, но скрытая') }

        expect(ids_for('справка')).to eq([visible_thread.id])
      end
    end

    it 'returns the threads of every inbox to an administrator' do
      admin = create(:user, account: account, role: :administrator)
      hidden_conversation = create(:conversation, account: account, inbox: other_inbox,
                                                  contact: create(:contact, account: account, name: 'Скрытый Иванов'))
      hidden_thread = thread_of(hidden_conversation)
      thread = thread_of(resolved_conversation)

      expect(found_ids(params, user: admin)).to contain_exactly(thread.id, hidden_thread.id)
    end

    it 'never returns the threads of another account' do
      thread = thread_of(resolved_conversation)
      other_account = create(:account)
      other_account.enable_features!('communication_threads')
      foreign_inbox = create(:inbox, account: other_account)
      foreign_contact = create(:contact, account: other_account, name: 'Иван Иванов', phone_number: '+77072817060')
      foreign_conversation = create(:conversation, account: other_account, inbox: foreign_inbox, contact: foreign_contact)
      foreign_thread = thread_of(foreign_conversation)
      create(:message, account: other_account, conversation: foreign_conversation, inbox: foreign_inbox, message_type: :incoming,
                       content: 'Нужна справка')

      aggregate_failures do
        expect(ids_for('Иванов')).to eq([thread.id])
        expect(ids_for('87072817060')).to eq([thread.id])
        expect(ids_for('справка')).to be_empty
        expect(ids_for(foreign_thread.display_id.to_s)).not_to include(foreign_thread.id)
      end
    end
  end

  describe 'result meta' do
    it 'reports the total, the page and that the search was run' do
      thread_of(resolved_conversation)

      expect(search[:count]).to include(search: true, total_count: 1, capped: false, partial: false, current_page: 1,
                                        per_page: described_class::PER_PAGE)
    end

    it 'pages the results and keeps the total of all pages' do
      stub_const("#{described_class}::PER_PAGE", 2)
      thread_of(resolved_conversation)
      3.times do |index|
        contact = create(:contact, account: account, name: "Пётр Иванов #{index}")
        thread_of(create(:conversation, account: account, inbox: inbox, contact: contact))
      end

      first_page = search(params)
      second_page = search(params.merge(page: 2))

      aggregate_failures do
        expect(first_page[:communication_threads].size).to eq(2)
        expect(second_page[:communication_threads].size).to eq(2)
        expect(first_page[:count][:total_count]).to eq(4)
        expect(second_page[:count]).to include(total_count: 4, current_page: 2)
        expect(first_page[:communication_threads].map(&:id) & second_page[:communication_threads].map(&:id)).to be_empty
      end
    end
  end
end
