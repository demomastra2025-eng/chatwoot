require 'rails_helper'

# The search box of the conversation list (derives from e/search commits c0c6939ef and ace4be3c0): server side, over all
# statuses and assignees, literal message text, permission scope.
RSpec.describe Conversations::ListSearchService do
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
    create(:inbox_member, user: agent, inbox: inbox)
    create(:inbox_member, user: colleague, inbox: inbox)
  end

  def search(search_params = params, user: agent)
    described_class.new(user: user, account: account, params: ActionController::Parameters.new(search_params)).perform
  end

  def ids_for(query, user: agent)
    found_ids({ q: query }, user: user)
  end

  def found_ids(search_params = params, user: agent)
    search(search_params, user: user)[:conversations].map(&:id)
  end

  def message_in(conversation, content, **attributes)
    create(:message, account: account, conversation: conversation, inbox: conversation.inbox, message_type: :incoming, content: content,
                     **attributes)
  end

  describe 'list filters' do
    let!(:open_mine) { create(:conversation, account: account, inbox: inbox, contact: ivan, status: :open, assignee: agent) }
    let!(:snoozed_unassigned) { create(:conversation, account: account, inbox: inbox, contact: ivan, status: :snoozed) }
    let!(:pending_conversation) { create(:conversation, account: account, inbox: inbox, contact: ivan, status: :pending) }

    it 'searches all statuses and all assignees' do
      expect(found_ids).to match_array([resolved_conversation, open_mine, snoozed_unassigned, pending_conversation].map(&:id))
    end

    it 'ignores the status, assignee, inbox, team, label, unread and CRM filters of the list' do
      team = create(:team, account: account)
      filters = {
        status: 'open', assignee_type: 'me', inbox_id: other_inbox.id, team_id: team.id, team_scope: 'any', labels: ['vip'],
        labels_scope: 'any', unread: 'true', conversation_type: 'mention', crm_pipeline_id: 1, crm_stage_id: 2,
        appointment_status: 'confirmed', source_id: 'nothing', sort_by: 'priority_asc', updated_within: 1
      }

      expect(found_ids(params.merge(filters))).to match_array([resolved_conversation, open_mine, snoozed_unassigned, pending_conversation].map(&:id))
    end

    it 'does not hide conversations that exist in an inbox other than the filtered one' do
      second_contact = create(:contact, account: account, name: 'Анна Иванова')
      create(:inbox_member, user: agent, inbox: other_inbox)
      other_inbox_conversation = create(:conversation, account: account, inbox: other_inbox, contact: second_contact)

      expect(found_ids(params.merge(inbox_id: inbox.id))).to include(other_inbox_conversation.id)
    end
  end

  describe 'what is found' do
    it 'finds a conversation by a phone number typed in any format' do
      aggregate_failures do
        ['87072817060', '+77072817060', '7 707 281 70 60', '+7 (707) 281-70-60', '707 281 70 60', '8-707-281-70-60', '2817060',
         "+7\u00A0707\u00A0281\u00A070\u00A060"].each do |query|
          expect(ids_for(query)).to eq([resolved_conversation.id]), "expected #{query.inspect} to find the conversation of the contact"
        end
      end
    end

    it 'finds a conversation by the contact name in any word order, with е and ё interchangeable' do
      yo = create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account, name: 'Семён Киселёв'))

      aggregate_failures do
        expect(ids_for('иванов иван')).to eq([resolved_conversation.id])
        expect(ids_for('киселев семен')).to eq([yo.id])
      end
    end

    it 'finds a channel handle and a phone number stored on the channel profile' do
      profile = resolved_conversation.contact_inbox.channel_profile ||
                create(:contact_channel_profile, contact_inbox: resolved_conversation.contact_inbox)
      profile.update!(username: 'ada_channel_login', phone_number: '+77075550101')

      expect(ids_for('ada_channel_login')).to eq([resolved_conversation.id])
      expect(ids_for('8 707 555 01 01')).to eq([resolved_conversation.id])
    end

    it 'does not find a conversation through a profile from another inbox' do
      private_channel = create(:contact_inbox, contact: ivan, inbox: other_inbox)
      create(:contact_channel_profile, contact_inbox: private_channel, username: 'private_handle')

      expect(ids_for('private_handle')).to be_empty
    end

    it 'finds a social handle stored on the contact' do
      ivan.update!(additional_attributes: { social_telegram_user_name: 'ada_telegram' })

      expect(ids_for('ada_telegram')).to eq([resolved_conversation.id])
    end

    it 'finds the transcript of an audio attachment' do
      recording = message_in(resolved_conversation, '')
      Attachment.create!(account: account, message: recording, file_type: :audio,
                         meta: { transcribed_text: 'Нужна справка по записи' })

      expect(ids_for('справка по записи')).to eq([resolved_conversation.id])
    end

    it 'finds the text fields of a message shown by the old local list search' do
      message_in(resolved_conversation, '', content_attributes: { email: { subject: 'Вопрос по приёму' } })

      expect(ids_for('вопрос по приему')).to eq([resolved_conversation.id])
    end

    it 'finds a conversation by the text of a message exactly as typed, without word forms' do
      message_in(resolved_conversation, 'Хочу записаться на приём')
      other = create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account, name: 'Мария'))
      message_in(other, 'Мы записали вас на среду', message_type: :outgoing)

      aggregate_failures do
        expect(ids_for('записаться')).to eq([resolved_conversation.id])
        expect(ids_for('записали')).to eq([other.id])
        expect(ids_for('запис')).to contain_exactly(resolved_conversation.id, other.id)
        expect(ids_for('на приём')).to eq([resolved_conversation.id])
        expect(ids_for('на прием')).to eq([resolved_conversation.id])
      end
    end

    it 'does not return a conversation twice when several of its messages match' do
      2.times { |index| message_in(resolved_conversation, "Нужна справка номер #{index}") }

      expect(ids_for('справка')).to eq([resolved_conversation.id])
    end

    it 'does not search activity messages' do
      message_in(resolved_conversation, 'Системное сообщение про справку', message_type: :activity)

      expect(ids_for('справку')).to be_empty
    end

    it 'finds a conversation by its number' do
      expect(ids_for(resolved_conversation.display_id.to_s)).to eq([resolved_conversation.id])
      expect(ids_for("##{resolved_conversation.display_id}")).to eq([resolved_conversation.id])
    end

    it 'finds nothing for a blank query or one that is too short to search' do
      aggregate_failures do
        expect(ids_for('')).to be_empty
        expect(ids_for('  ')).to be_empty
        expect(found_ids({})).to be_empty
        expect(ids_for('Ив')).to be_empty
      end
    end

    it 'does not look at the contacts at all for a text that is too short, a conversation number included' do
      allow(Search::ContactQuery).to receive(:new).and_call_original
      short_number = resolved_conversation.display_id.to_s
      expect(short_number.length).to be < Search::ConversationLookup::MIN_TEXT_LENGTH

      expect(ids_for('Ив')).to be_empty
      expect(ids_for(short_number)).to eq([resolved_conversation.id])

      expect(Search::ContactQuery).not_to have_received(:new)
    end

    it 'orders the conversations by their latest activity' do
      older = create(:conversation, account: account, inbox: inbox, contact: ivan, last_activity_at: 3.days.ago)
      newer = create(:conversation, account: account, inbox: inbox, contact: ivan, last_activity_at: 1.minute.ago)
      resolved_conversation.update_columns(last_activity_at: 1.day.ago) # rubocop:disable Rails/SkipsModelValidations -- fix the order under test

      expect(found_ids).to eq([newer.id, resolved_conversation.id, older.id])
    end
  end

  describe 'who may see what' do
    it 'never returns a conversation of an inbox the agent is not a member of' do
      hidden_contact = create(:contact, account: account, name: 'Скрытый Иванов', phone_number: '+77015550000')
      hidden = create(:conversation, account: account, inbox: other_inbox, contact: hidden_contact)
      message_in(hidden, 'Секретная справка')

      aggregate_failures do
        expect(ids_for('Иванов')).not_to include(hidden.id)
        expect(ids_for('8 701 555 00 00')).to be_empty
        expect(ids_for('секретная')).to be_empty
        expect(ids_for(hidden.display_id.to_s)).to be_empty
      end
    end

    it 'does not leak a social handle from an inaccessible conversation' do
      private_contact = create(:contact, account: account, additional_attributes: { screen_name: 'private_screen' })
      create(:conversation, account: account, inbox: other_inbox, contact: private_contact)

      expect(ids_for('private_screen')).to be_empty
    end

    it 'does not let messages of inaccessible inboxes use up the message limit' do
      stub_const('Search::ConversationLookup::MESSAGE_LIMIT', 2)
      hidden = create(:conversation, account: account, inbox: other_inbox, contact: create(:contact, account: account))
      3.times { message_in(hidden, 'Нужна справка') }
      message_in(resolved_conversation, 'Нужна справка', created_at: 2.days.ago)

      expect(ids_for('справка')).to eq([resolved_conversation.id])
    end

    context 'with a custom role that opens fewer conversations than its inbox holds' do
      let(:hidden_contact) { create(:contact, account: account, name: 'Скрытый Петров', phone_number: '+77015550000') }
      # in an inbox of the agent, but unassigned and without the agent taking part: not for this role
      let!(:hidden) { create(:conversation, account: account, inbox: inbox, contact: hidden_contact) }
      let!(:visible) { create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account), assignee: agent) }

      before do
        custom_role = create(:custom_role, account: account, permissions: ['conversation_participating_manage'])
        agent.account_users.find_by(account: account).update!(custom_role: custom_role)
        message_in(hidden, 'Секретная справка про диагноз')
        message_in(visible, 'Нужная справка для вас')
      end

      it 'never leads to a conversation the role cannot open, through the text of its messages, its contact or its number' do
        aggregate_failures do
          expect(ids_for('справка')).to eq([visible.id])
          expect(ids_for('секретная справка')).to be_empty
          expect(ids_for('Секретный')).to be_empty
          expect(ids_for('Скрытый')).to be_empty
          expect(ids_for('8 701 555 00 00')).to be_empty
          expect(ids_for(hidden.display_id.to_s)).to be_empty
        end
      end

      it 'does not let the messages of conversations the role cannot open use up the message limit' do
        stub_const('Search::ConversationLookup::MESSAGE_LIMIT', 2)
        3.times { message_in(hidden, 'Нужная справка, но скрытая') }

        expect(ids_for('справка')).to eq([visible.id])
      end
    end

    it 'returns the conversations of every inbox to an administrator' do
      admin = create(:user, account: account, role: :administrator)
      hidden = create(:conversation, account: account, inbox: other_inbox, contact: ivan)

      expect(found_ids(params, user: admin)).to contain_exactly(resolved_conversation.id, hidden.id)
    end

    it 'never returns the conversations of another account' do
      other_account = create(:account)
      foreign_inbox = create(:inbox, account: other_account)
      foreign_contact = create(:contact, account: other_account, name: 'Иван Иванов', phone_number: '+77072817060')
      foreign = create(:conversation, account: other_account, inbox: foreign_inbox, contact: foreign_contact)
      create(:message, account: other_account, conversation: foreign, inbox: foreign_inbox, message_type: :incoming, content: 'Нужна справка')

      aggregate_failures do
        expect(ids_for('Иванов')).to eq([resolved_conversation.id])
        expect(ids_for('87072817060')).to eq([resolved_conversation.id])
        expect(ids_for('справка')).to be_empty
      end
    end
  end

  describe 'result meta' do
    it 'reports the total, the page and that the search was run' do
      expect(search[:meta]).to include(search: true, total_count: 1, capped: false, partial: false, current_page: 1,
                                       per_page: described_class::PER_PAGE)
    end

    it 'pages the results and keeps the total of all pages' do
      stub_const("#{described_class}::PER_PAGE", 2)
      3.times { create(:conversation, account: account, inbox: inbox, contact: ivan) }

      first_page = search(params)
      second_page = search(params.merge(page: 2))

      aggregate_failures do
        expect(first_page[:conversations].size).to eq(2)
        expect(second_page[:conversations].size).to eq(2)
        expect(first_page[:meta][:total_count]).to eq(4)
        expect(second_page[:meta]).to include(total_count: 4, current_page: 2)
        shown = first_page[:conversations].map(&:id) + second_page[:conversations].map(&:id)
        expect(shown).to match_array(Conversation.where(contact: ivan).pluck(:id))
      end
    end

    it 'still finds the contacts and says so when the search of the message text ran out of time' do
      message_in(resolved_conversation, 'Нужна справка')
      allow_any_instance_of(Search::MessageQuery).to receive(:newest).and_return(Search::MessageQuery::Result.new([], true)) # rubocop:disable RSpec/AnyInstance

      result = search({ q: 'Иванов' })

      expect(result[:conversations].map(&:id)).to eq([resolved_conversation.id])
      expect(result[:meta][:partial]).to be(true)
    end

    it 'says so when the newest matches were cut at the limit' do
      stub_const('Search::ConversationLookup::MESSAGE_LIMIT', 2)
      3.times { message_in(resolved_conversation, 'Нужна справка') }

      expect(search({ q: 'справка' })[:meta][:capped]).to be(true)
    end
  end
end
