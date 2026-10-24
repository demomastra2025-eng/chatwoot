require 'rails_helper'

# Labels belong to a person. Every path that adds or removes one writes the contact and every conversation of the person
# through Labels::UnifiedAssignmentService, and the change is reported once, however many channels the person has.
# This spec crosses many classes on purpose: it is the list of paths that must go through the one write point.
RSpec.describe 'Person label write paths' do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:contact) { create(:contact, account: account) }
  let!(:conversation) { create(:conversation, account: account, contact: contact) }
  let!(:second_conversation) { create(:conversation, account: account, contact: contact) }
  let!(:third_conversation) { create(:conversation, account: account, contact: contact) }
  let(:dispatched) { [] }

  def person_lists
    [contact, conversation, second_conversation, third_conversation].map { |record| record.reload.label_list.to_a }
  end

  def conversation_updated_count
    dispatched.count(Events::Types::CONVERSATION_UPDATED)
  end

  before do
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, *args|
      dispatched << args.first
      original.call(*args)
    end
  end

  after { Current.reset }

  describe 'automation rule actions' do
    def run_rule(actions)
      rule = create(:automation_rule, account: account, actions: actions)
      dispatched.clear
      AutomationRules::ActionService.new(rule, account, conversation).perform
    end

    it 'add_label lands on the contact and every conversation of the person and is reported once' do
      expect { run_rule([{ 'action_name' => 'add_label', 'action_params' => %w[vip] }]) }
        .to have_enqueued_job(Conversations::ActivityMessageJob).once

      expect(person_lists).to all(eq(%w[vip]))
      expect(conversation_updated_count).to eq(1)
    end

    it 'remove_label takes the label off the contact and every conversation of the person' do
      Labels::UnifiedAssignmentService.add(contact: contact, labels: %w[vip support], silent: true)
      contact.update_labels(%w[vip support card_only])

      run_rule([{ 'action_name' => 'remove_label', 'action_params' => %w[vip card_only] }])

      expect(person_lists).to all(eq(%w[support]))
      expect(conversation_updated_count).to eq(1)
    end

    it 'leaves another person alone' do
      stranger = create(:conversation, account: account)

      run_rule([{ 'action_name' => 'add_label', 'action_params' => %w[vip] }])

      expect(stranger.reload.label_list).to be_empty
      expect(stranger.contact.reload.label_list).to be_empty
    end

    it 'applies add_label and remove_label of one rule in order, each reported once' do
      run_rule([{ 'action_name' => 'add_label', 'action_params' => %w[vip support] },
                { 'action_name' => 'remove_label', 'action_params' => %w[support] }])

      expect(person_lists).to all(eq(%w[vip]))
      expect(conversation_updated_count).to eq(2)
    end
  end

  describe 'macros' do
    def run_macro(actions)
      macro = create(:macro, account: account, actions: actions)
      dispatched.clear
      Macros::ExecutionService.new(macro, conversation, user).perform
    end

    it 'add_label lands on the contact and every conversation of the person and is reported once' do
      expect { run_macro([{ 'action_name' => 'add_label', 'action_params' => %w[vip] }]) }
        .to have_enqueued_job(Conversations::ActivityMessageJob).once

      expect(person_lists).to all(eq(%w[vip]))
      expect(conversation_updated_count).to eq(1)
    end

    it 'remove_label takes the label off everywhere' do
      Labels::UnifiedAssignmentService.add(contact: contact, labels: %w[vip], silent: true)

      run_macro([{ 'action_name' => 'remove_label', 'action_params' => %w[vip] }])

      expect(person_lists).to all(be_empty)
    end
  end

  describe 'labels set or taken off on the WhatsApp phone' do
    let(:channel) { create(:channel_whatsapp_web, account: account) }
    let(:phone_contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: phone_contact, inbox: channel.inbox, source_id: '77011234567') }
    let!(:phone_conversation) do
      create(:conversation, account: account, contact: phone_contact, inbox: channel.inbox, contact_inbox: contact_inbox)
    end
    let!(:other_channel_conversation) { create(:conversation, account: account, contact: phone_contact) }
    let(:service) { WhatsappWeb::LabelSyncService.new(channel: channel) }
    let(:association) { { 'chatId' => '77011234567@s.whatsapp.net', 'labelId' => '5', 'type' => 'add' } }

    before { service.sync_label_definition('id' => '5', 'name' => 'VIP', 'color' => '#ff0000') }

    it 'puts the label on the person, not only on the chat' do
      service.sync_label_association(association)

      expect(phone_contact.reload.label_list).to eq(%w[wa_vip])
      expect(phone_conversation.reload.label_list).to eq(%w[wa_vip])
      expect(other_channel_conversation.reload.label_list).to eq(%w[wa_vip])
    end

    it 'takes the label off the person when it is removed on the phone' do
      service.sync_label_association(association)

      service.sync_label_association(association.merge('type' => 'remove'))

      expect(phone_contact.reload.label_list).to be_empty
      expect([phone_conversation, other_channel_conversation].map { |record| record.reload.label_list.to_a }).to all(be_empty)
    end
  end

  describe 'the auto-resolve label' do
    let(:label) { create(:label, title: 'auto-resolved', account: account) }

    before do
      account.update!(auto_resolve_after: 14_400, auto_resolve_ignore_waiting: false, auto_resolve_label: label.title)
      conversation.update!(last_activity_at: 13.days.ago, waiting_since: nil)
    end

    it 'goes to the person, while only the idle conversation is resolved' do
      Conversations::ResolutionJob.perform_now(account: account)

      expect(conversation.reload).to be_resolved
      expect(second_conversation.reload).to be_open
      expect(person_lists).to all(eq(%w[auto-resolved]))
    end
  end

  describe 'bulk actions on people' do
    let(:other_contact) { create(:contact, account: account) }

    before { create(:conversation, account: account, contact: other_contact) }

    it 'adds and removes labels on the contact and every conversation, one change per person' do
      Labels::UnifiedAssignmentService.add(contact: other_contact, labels: %w[old], silent: true)

      Contacts::BulkAssignLabelsService.new(
        account: account, contact_ids: [contact.id, other_contact.id], labels: %w[vip], remove_labels: %w[old]
      ).perform

      expect(person_lists).to all(eq(%w[vip]))
      expect(other_contact.reload.label_list).to eq(%w[vip])
      expect(other_contact.conversations.map { |record| record.reload.label_list.to_a }).to all(eq(%w[vip]))
    end

    it 'removes labels through the contacts bulk action service' do
      Labels::UnifiedAssignmentService.add(contact: contact, labels: %w[vip paid], silent: true)

      Contacts::BulkActionService.new(
        account: account, user: user, params: { ids: [contact.id], labels: { remove: %w[vip] } }
      ).perform

      expect(person_lists).to all(eq(%w[paid]))
    end
  end
end
