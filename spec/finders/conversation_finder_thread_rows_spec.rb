# frozen_string_literal: true

require 'rails_helper'

# The lists of conversations (the label view, a team, an inbox, a folder) show one row per person, like the main list of
# threads: the conversations of one communication thread belong to the same contact.
RSpec.describe ConversationFinder do
  let(:account) do
    create(:account, limits: { non_web_inboxes: ChatwootApp.max_limit }).tap { |record| record.enable_features!('communication_threads') }
  end
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:contact) { create(:contact, account: account, phone_number: '+77011234567') }
  let(:voice_inbox) { create(:channel_voice, :sipuni, account: account).inbox }
  let(:whatsapp_inbox) { create(:channel_whatsapp_web, account: account).inbox }

  # Several open conversations of one person, put there without the live rule (the data that exists in production). The
  # conversations are created resolved, because the live rule only looks at open ones, and get their status afterwards.
  def dialog(inbox, minutes_ago:, status: 'open', contact: self.contact, labels: nil)
    create(:conversation, account: account, contact: contact, inbox: inbox, status: :resolved).tap do |conversation|
      conversation.update_labels(labels) if labels
      conversation.update_columns(last_activity_at: minutes_ago.minutes.ago) # rubocop:disable Rails/SkipsModelValidations
      statuses_to_apply[conversation.id] = status unless status == 'resolved'
    end
  end

  def statuses_to_apply
    @statuses_to_apply ||= {}
  end

  def apply_statuses!
    statuses_to_apply.each do |id, status|
      Conversation.where(id: id).update_all(status: Conversation.statuses.fetch(status)) # rubocop:disable Rails/SkipsModelValidations
    end
    statuses_to_apply.clear
  end

  def listed(**params)
    described_class.new(admin, params, account).perform
  end

  before { Current.account = account }

  after { Current.reset }

  describe 'the label view' do
    let!(:voice) { dialog(voice_inbox, minutes_ago: 1, labels: %w[vip]) }
    let!(:chat) { dialog(whatsapp_inbox, minutes_ago: 20, labels: %w[vip]) }
    let!(:other_person) { dialog(whatsapp_inbox, minutes_ago: 5, contact: create(:contact, account: account), labels: %w[vip]) }

    before { apply_statuses! }

    it 'lists one row for a person who has two open conversations with the label', :aggregate_failures do
      result = listed(labels: %w[vip], status: 'open')

      expect(result[:conversations].map(&:id)).to contain_exactly(voice.id, other_person.id)
      expect(result[:count]).to include(all_count: 2)
    end

    it 'keeps the open conversation with the latest activity of the person' do
      expect(listed(labels: %w[vip], status: 'open')[:conversations].map(&:id)).not_to include(chat.id)
    end

    it 'counts the same rows in the meta request as the list shows', :aggregate_failures do
      meta = described_class.new(admin, { labels: %w[vip], status: 'open' }, account).perform_meta_only

      expect(meta[:count]).to include(all_count: 2, mine_count: 0, unassigned_count: 2)
    end

    it 'keeps the assignee filter on the shown row', :aggregate_failures do
      voice.update_columns(assignee_id: admin.id) # rubocop:disable Rails/SkipsModelValidations

      mine = listed(labels: %w[vip], status: 'open', assignee_type: 'me')[:conversations]

      expect(mine.map(&:id)).to eq([voice.id])
    end

    it 'prefers the open conversation over a more recent resolved one' do
      # Creating the resolved conversation refreshes the thread: the messenger (20 minutes ago) stays open, the call is resolved.
      resolved_later = dialog(whatsapp_inbox, minutes_ago: 0, status: 'resolved', labels: %w[vip])

      ids = listed(labels: %w[vip], status: 'all')[:conversations].map(&:id)

      expect(ids).to include(chat.id)
      expect(ids).not_to include(voice.id, resolved_later.id)
    end

    it 'finds a person whose only conversation with the label is a resolved one' do
      only_old = create(:contact, account: account)
      old_conversation = dialog(whatsapp_inbox, minutes_ago: 9000, status: 'resolved', contact: only_old, labels: %w[vip])
      dialog(voice_inbox, minutes_ago: 3, contact: only_old)
      apply_statuses!

      expect(listed(labels: %w[vip], status: 'all')[:conversations].map(&:id)).to include(old_conversation.id)
    end

    it 'shows one row for a person with several resolved conversations' do
      voice.update_columns(status: Conversation.statuses.fetch('resolved')) # rubocop:disable Rails/SkipsModelValidations
      chat.update_columns(status: Conversation.statuses.fetch('resolved')) # rubocop:disable Rails/SkipsModelValidations
      older = dialog(whatsapp_inbox, minutes_ago: 5000, status: 'resolved', labels: %w[vip])
      newer = dialog(voice_inbox, minutes_ago: 2500, status: 'resolved', labels: %w[vip])

      ids = listed(labels: %w[vip], status: 'resolved')[:conversations].map(&:id)

      expect(ids).to include(voice.id)
      expect(ids).not_to include(chat.id, older.id, newer.id)
    end
  end

  describe 'other lists' do
    let!(:voice) { dialog(voice_inbox, minutes_ago: 1) }
    let!(:chat) { dialog(whatsapp_inbox, minutes_ago: 30) }

    before { apply_statuses! }

    it 'applies to the inbox list and to the unfiltered list' do
      expect(listed(inbox_id: whatsapp_inbox.id, status: 'open')[:conversations].map(&:id)).to eq([chat.id])
      expect(listed(status: 'open')[:conversations].map(&:id)).to eq([voice.id])
    end

    it 'applies to the bulk selection of a list', :aggregate_failures do
      scope = described_class.new(admin, { status: 'open' }, account).selection_scope

      expect(scope.pluck(:id)).to eq([voice.id])
    end

    it 'shows the conversations of an account without communication threads as they are' do
      account.disable_features!('communication_threads')

      expect(listed(status: 'open')[:conversations].map(&:id)).to contain_exactly(voice.id, chat.id)
    end

    it 'does not hide a conversation that matched a text search' do
      create(:message, conversation: voice, account: account, inbox: voice_inbox, message_type: :incoming, content: 'needle in a haystack')
      create(:message, conversation: chat, account: account, inbox: whatsapp_inbox, message_type: :incoming, content: 'needle in a haystack')

      expect(listed(q: 'needle', status: 'open')[:conversations].map(&:id)).to contain_exactly(voice.id, chat.id)
    end

    it 'leaves conversations without a thread as their own row' do
      lone = create(:conversation, account: account, contact: create(:contact, account: account), status: :open)
      CommunicationThreadConversation.where(conversation_id: lone.id).delete_all

      expect(listed(status: 'open')[:conversations].map(&:id)).to contain_exactly(voice.id, lone.id)
    end
  end

  describe Conversations::FilterService do
    it 'shows one row per person in a saved folder (advanced filter)', :aggregate_failures do
      voice = dialog(voice_inbox, minutes_ago: 1)
      dialog(whatsapp_inbox, minutes_ago: 30)
      apply_statuses!
      status_filter = { attribute_key: 'status', filter_operator: 'equal_to', values: %w[open], query_operator: nil,
                        custom_attribute_type: '' }.with_indifferent_access

      result = described_class.new({ payload: [status_filter], page: 1 }, admin, account).perform

      expect(result[:conversations].map(&:id)).to eq([voice.id])
      expect(result[:count]).to include(all_count: 1)
    end
  end
end
