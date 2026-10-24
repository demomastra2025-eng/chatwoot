# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Labels::ConversationScope do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:scope) { account.conversations }

  def create_conversation(contact: create(:contact, account: account), status: :open)
    create(:conversation, account: account, inbox: inbox, contact: contact, status: status)
  end

  describe '.with_labels' do
    it 'matches a conversation whose contact carries the label while the conversation does not' do
      wife = create(:contact, account: account)
      wife.update_labels('Семья')
      telegram = create_conversation(contact: wife)
      whatsapp = create_conversation(contact: wife, status: :pending)

      expect(described_class.with_labels(scope, ['Семья']).pluck(:id)).to contain_exactly(telegram.id, whatsapp.id)
    end

    it 'matches a conversation that carries the label itself' do
      conversation = create_conversation
      conversation.update_labels('Семья')

      expect(described_class.with_labels(scope, ['Семья']).pluck(:id)).to contain_exactly(conversation.id)
    end

    it 'lists a conversation once when the contact and the conversation both carry the label' do
      mother = create(:contact, account: account)
      mother.update_labels(%w[Семья vip])
      conversation = create_conversation(contact: mother)
      conversation.update_labels(%w[Семья vip])

      result = described_class.with_labels(scope, %w[Семья vip])

      expect(result.to_a.map(&:id)).to eq([conversation.id])
      expect(result.count).to eq(1)
    end

    it 'does not match when neither the conversation nor the contact carries the label' do
      create_conversation
      other_label = create_conversation
      other_label.update_labels('vip')
      other_contact = create(:contact, account: account)
      other_contact.update_labels('vip')
      create_conversation(contact: other_contact)

      expect(described_class.with_labels(scope, ['Семья']).pluck(:id)).to be_empty
    end

    it 'does not match the conversations of another contact' do
      wife = create(:contact, account: account)
      wife.update_labels('Семья')
      create_conversation(contact: wife)
      stranger_conversation = create_conversation

      expect(described_class.with_labels(scope, ['Семья']).pluck(:id)).not_to include(stranger_conversation.id)
    end

    it 'matches any of several labels and ignores the case of the label name like tagged_with' do
      first = create(:contact, account: account)
      first.update_labels('Family')
      second = create(:contact, account: account)
      second.update_labels('Friends')
      first_conversation = create_conversation(contact: first)
      second_conversation = create_conversation(contact: second)
      create_conversation

      expect(described_class.with_labels(scope, %w[family FRIENDS]).pluck(:id))
        .to contain_exactly(first_conversation.id, second_conversation.id)
    end

    it 'matches nothing for an unknown or blank label list' do
      wife = create(:contact, account: account)
      wife.update_labels('Семья')
      create_conversation(contact: wife)

      expect(described_class.with_labels(scope, ['unknown']).pluck(:id)).to be_empty
      expect(described_class.with_labels(scope, ['']).pluck(:id)).to be_empty
      expect(described_class.with_labels(scope, []).pluck(:id)).to be_empty
    end

    it 'keeps the conditions of the scope it is given' do
      wife = create(:contact, account: account)
      wife.update_labels('Семья')
      open_conversation = create_conversation(contact: wife)
      create_conversation(contact: wife, status: :resolved)

      result = described_class.with_labels(scope.where(status: :open), ['Семья'])

      expect(result.pluck(:id)).to contain_exactly(open_conversation.id)
    end
  end

  describe '.match_sql' do
    it 'looks the labels up once per query, not once per conversation' do
      sql = described_class.match_sql([1, 2])

      expect(sql).not_to include('EXISTS')
      expect(sql.scan('= ANY (ARRAY(SELECT').size).to eq(2)
      expect(sql).to include('label_taggings.tag_id IN (1, 2)')
      expect(sql).not_to include('label_taggings.taggable_id =')
    end

    it 'is never NULL, so NOT finds a conversation without a contact and without a label' do
      labeled_contact = create(:contact, account: account)
      labeled_contact.update_labels('Семья')
      labeled = create_conversation(contact: labeled_contact)
      unlabeled = create_conversation
      contactless = create_conversation.tap { |conversation| conversation.update_column(:contact_id, nil) }

      by_name = described_class.match_sql(described_class.tag_ids_for(['Семья']))

      expect(scope.where("NOT #{by_name}").pluck(:id)).to contain_exactly(unlabeled.id, contactless.id)
      expect(scope.where("NOT #{described_class.match_sql}").pluck(:id)).to contain_exactly(unlabeled.id, contactless.id)
      expect(scope.where(by_name).pluck(:id)).to contain_exactly(labeled.id)
    end
  end

  describe '.match_tags_sql' do
    it 'takes the tag ids as a subquery' do
      wife = create(:contact, account: account)
      wife.update_labels('Семья')
      by_contact = create_conversation(contact: wife)
      other = create(:contact, account: account)
      other.update_labels('vip')
      create_conversation(contact: other)
      by_conversation = create_conversation
      by_conversation.update_labels('Семья')

      sql = described_class.match_tags_sql("SELECT tags.id FROM tags WHERE tags.name IN ('Семья')")

      expect(scope.where(sql).pluck(:id)).to contain_exactly(by_contact.id, by_conversation.id)
    end
  end

  describe '.with_any_label' do
    it 'matches conversations that have a label on the contact or on the conversation, once each' do
      labeled_contact = create(:contact, account: account)
      labeled_contact.update_labels(%w[Семья vip])
      by_contact = create_conversation(contact: labeled_contact)
      by_conversation = create_conversation
      by_conversation.update_labels(%w[a b])
      by_both_contact = create(:contact, account: account)
      by_both_contact.update_labels('a')
      by_both = create_conversation(contact: by_both_contact)
      by_both.update_labels(%w[a b])
      create_conversation

      result = described_class.with_any_label(scope)

      expect(result.to_a.map(&:id)).to contain_exactly(by_contact.id, by_conversation.id, by_both.id)
      expect(result.count).to eq(3)
    end

    it 'matches nothing when no conversation and no contact has a label' do
      create_conversation

      expect(described_class.with_any_label(scope).pluck(:id)).to be_empty
    end
  end
end
