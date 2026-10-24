# frozen_string_literal: true

require 'rails_helper'

# One person, one status: a person (a communication thread) is in exactly one status tab, the tab of the thread status (the most
# urgent status of its channels), and the counters of a tab are the size of its list. The statuses of the single channels do
# not put a person into a second tab.
RSpec.describe CommunicationThreadFinder do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }
  let(:user) { create(:user, account: account, role: :administrator) }

  # name => [statuses of the channels, status of the person]
  let(:roster) do
    {
      'open and resolved' => [%w[open resolved], 'open'],
      'open and snoozed' => [%w[open snoozed], 'open'],
      'all four statuses' => [%w[resolved snoozed pending open], 'open'],
      'pending and resolved' => [%w[pending resolved], 'pending'],
      'snoozed and resolved' => [%w[snoozed resolved], 'snoozed'],
      'two snoozed' => [%w[snoozed snoozed], 'snoozed'],
      'resolved twice' => [%w[resolved resolved], 'resolved']
    }
  end

  let!(:people) do
    roster.transform_values do |statuses, _expected|
      contact = create(:contact, account: account)
      conversations = statuses.map do |status|
        inbox = create(:inbox, account: account)
        create(:conversation, account: account, contact: contact, inbox: inbox,
                              contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox), status: :resolved).tap do |conversation|
          conversation.update_columns(status: Conversation.statuses.fetch(status)) # rubocop:disable Rails/SkipsModelValidations
        end
      end
      Conversations::CommunicationThreadResolver.new(conversation: conversations.first.reload, enforce_single_open_dialog: false).perform
    end
  end

  before { Current.account = account }

  after { Current.reset }

  def tab_statuses
    %w[open pending snoozed resolved]
  end

  def tab(status, extra = {})
    described_class.new(user, { status: status, assignee_type: 'all' }.merge(extra)).perform
  end

  def tab_names(status, extra = {})
    ids = tab(status, extra)[:communication_threads].map(&:id)
    people.select { |_name, thread| ids.include?(thread.id) }.keys
  end

  def expected_names(status)
    roster.select { |_name, (_statuses, person_status)| person_status == status }.keys
  end

  it 'gives every person the most urgent status of its channels' do
    expect(people.transform_values(&:status)).to eq(roster.transform_values(&:last))
  end

  it 'lists each person in the tab of the thread status only', :aggregate_failures do
    tab_statuses.each do |status|
      expect(tab_names(status)).to match_array(expected_names(status)), "tab #{status}"
    end
  end

  it 'never puts a person in two tabs', :aggregate_failures do
    names_per_tab = tab_statuses.flat_map { |status| tab_names(status) }

    expect(names_per_tab).to match_array(roster.keys)
    expect(tab_names('all')).to match_array(roster.keys)
  end

  it 'counts exactly the persons of the list in each tab', :aggregate_failures do
    tab_statuses.each do |status|
      result = tab(status)

      expect(result[:count][:all_count]).to eq(expected_names(status).size), "all_count of #{status}"
      expect(result[:count][:all_count]).to eq(result[:communication_threads].total_count)
      expect(described_class.new(user, { status: status, assignee_type: 'all' }).perform_meta_only[:count][:all_count])
        .to eq(expected_names(status).size)
    end
  end

  it 'matches the inbox by any channel of the person but the status by the person', :aggregate_failures do
    open_and_resolved = people.fetch('open and resolved')
    resolved_channel_inbox = open_and_resolved.conversations.find(&:resolved?).inbox_id

    expect(tab_names('open', inbox_id: resolved_channel_inbox)).to eq(['open and resolved'])
    expect(tab_names('resolved', inbox_id: resolved_channel_inbox)).to be_empty
  end

  it 'counts the unread persons per status tab under the status of the thread', :aggregate_failures do
    counts = CommunicationThreads::UnreadStatusCountService.new(
      account: account, thread_scope: CommunicationThread.where(account_id: account.id)
    ).perform

    expect(counts).to eq(tab_statuses.index_with { |status| expected_names(status).size })
  end
end
