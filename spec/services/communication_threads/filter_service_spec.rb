# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationThreads::FilterService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account, enable_auto_assignment: false) }
  let(:hidden_inbox) do
    create(:inbox, account: account, enable_auto_assignment: false).tap do |target_inbox|
      target_inbox.inbox_members.where(user: user).destroy_all
    end
  end
  let(:params) { { payload: [], page: 1 } }
  let(:wife_thread) do
    # Telegram open + WhatsApp pending, the conversations carry no label, only the contact does.
    thread_for(contact_label: 'Семья', status: :open).tap { |thread| add_conversation(thread.contact, status: :pending) }
  end
  let(:mother_thread) { thread_for(contact_label: 'Семья', conversation_label: 'Семья') }
  let(:conversation_only_thread) { thread_for(conversation_label: 'Семья') }
  let(:unlabeled_thread) { thread_for }
  let(:other_label_thread) { thread_for(contact_label: 'vip') }
  let(:labeled_ids) { [wife_thread.id, mother_thread.id, conversation_only_thread.id] }

  before do
    account.enable_features!('communication_threads')
    create(:inbox_member, user: user, inbox: inbox)
    [wife_thread, mother_thread, conversation_only_thread, unlabeled_thread, other_label_thread]
  end

  def thread_for(contact_label: nil, conversation_label: nil, status: :open, target_inbox: inbox)
    contact = create(:contact, account: account)
    contact.update_labels(contact_label) if contact_label
    conversation = add_conversation(contact, status: status, target_inbox: target_inbox)
    conversation.update_labels(conversation_label) if conversation_label
    conversation.reload.communication_thread
  end

  def add_conversation(contact, status:, target_inbox: inbox)
    create(:conversation, account: account, inbox: target_inbox, contact: contact, status: status)
  end

  def labels_condition(filter_operator, values = ['Семья'], query_operator: nil)
    { attribute_key: 'labels', filter_operator: filter_operator, values: values, query_operator: query_operator }.with_indifferent_access
  end

  def perform(payload, extra_params = {}, as: user)
    described_class.new(params.merge(payload: payload).merge(extra_params), as, account).perform
  end

  it 'matches a label on the conversation or on its contact with equal_to' do
    result = perform([labels_condition('equal_to')])

    expect(wife_thread.communication_thread_conversations.map { |link| link.conversation.label_list }).to all(be_empty)
    expect(result[:communication_threads].map(&:id)).to match_array(labeled_ids)
    expect(result[:count]).to include(all_count: 3)
  end

  it 'excludes both kinds of label with not_equal_to' do
    result = perform([labels_condition('not_equal_to')])

    expect(result[:communication_threads].map(&:id)).to contain_exactly(unlabeled_thread.id, other_label_thread.id)
    expect(result[:count]).to include(all_count: 2)
  end

  it 'treats a label on the contact as present' do
    present = perform([labels_condition('is_present', [])])
    absent = perform([labels_condition('is_not_present', [])])

    expect(present[:communication_threads].map(&:id)).to match_array(labeled_ids + [other_label_thread.id])
    expect(absent[:communication_threads].map(&:id)).to contain_exactly(unlabeled_thread.id)
  end

  it 'lists a person through a conversation that passes the other conditions of the filter' do
    pending_payload = [
      { attribute_key: 'status', filter_operator: 'equal_to', values: ['pending'], query_operator: 'AND' }.with_indifferent_access,
      labels_condition('equal_to')
    ]

    result = perform(pending_payload)

    expect(result[:communication_threads].map(&:id)).to contain_exactly(wife_thread.id)
    expect(result[:count]).to include(all_count: 1)
  end

  it 'keeps the permission filter: a person whose conversations the agent cannot open is not listed' do
    hidden_thread = thread_for(contact_label: 'Семья', target_inbox: hidden_inbox)

    result = perform([labels_condition('equal_to')])

    expect(result[:communication_threads].map(&:id)).not_to include(hidden_thread.id)
    expect(result[:count]).to include(all_count: 3)
    admin = create(:user, account: account, role: :administrator)
    expect(perform([labels_condition('equal_to')], {}, as: admin)[:communication_threads].map(&:id)).to include(hidden_thread.id)
  end

  it 'lists the same people for the any-label scope with matching counts' do
    result = perform([], { labels_scope: 'any' })

    expect(result[:communication_threads].map(&:id)).to match_array(labeled_ids + [other_label_thread.id])
    expect(result[:count]).to include(all_count: 4)
  end

  describe 'multi-channel thread where the label sits only on an older resolved conversation' do
    let!(:multichannel_thread) do
      contact = create(:contact, account: account)
      whatsapp_conv = add_conversation(contact, status: :resolved, target_inbox: inbox)
      whatsapp_conv.update_labels('первичка')
      voice_inbox = create(:inbox, account: account, enable_auto_assignment: false)
      create(:inbox_member, user: user, inbox: voice_inbox)
      voice_conv = create(
        :conversation,
        account: account,
        inbox: voice_inbox,
        contact: contact,
        contact_inbox: create(:contact_inbox, contact: contact, inbox: voice_inbox),
        status: :open
      )
      voice_conv.reload.communication_thread
    end

    it 'matches open status with peer-conversation labels and excludes negated label operators', :aggregate_failures do
      open_and_labeled = [
        { attribute_key: 'status', filter_operator: 'equal_to', values: ['open'], query_operator: 'AND' }.with_indifferent_access,
        labels_condition('equal_to', ['первичка'])
      ]
      matched = perform(open_and_labeled)
      expect(matched[:communication_threads].map(&:id)).to contain_exactly(multichannel_thread.id)

      excluded_by_negation = perform([labels_condition('not_equal_to', ['первичка'])])
      expect(excluded_by_negation[:communication_threads].map(&:id)).not_to include(multichannel_thread.id)

      excluded_by_not_present = perform([labels_condition('is_not_present', [])])
      expect(excluded_by_not_present[:communication_threads].map(&:id)).not_to include(multichannel_thread.id)
    end
  end
end
