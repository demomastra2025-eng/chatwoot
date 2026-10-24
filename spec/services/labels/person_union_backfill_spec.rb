require 'rails_helper'
require 'rake'

RSpec.describe Labels::PersonUnionBackfill do
  let(:account) { create(:account) }
  # Person with labels on the card and on one channel, and a second channel without any
  let(:contact) { create(:contact, account: account) }
  let!(:first_conversation) { create(:conversation, account: account, contact: contact) }
  let!(:second_conversation) { create(:conversation, account: account, contact: contact) }
  # Person that is already in order
  let(:settled_contact) { create(:contact, account: account) }
  let!(:settled_conversation) { create(:conversation, account: account, contact: settled_contact) }
  # Person with a card label and no conversation, and one without any label
  let!(:card_only_contact) { create(:contact, account: account) }

  before do
    create(:conversation, account: account)
    contact.update_labels(%w[card])
    first_conversation.update_labels(%w[channel])
    settled_contact.update_labels(%w[settled])
    settled_conversation.update_labels(%w[settled])
    card_only_contact.update_labels(%w[alone])
  end

  def lists(*records)
    records.map { |record| record.reload.label_list.to_a }
  end

  describe 'a dry run' do
    it 'counts what would change' do
      result = described_class.new(account_id: account.id).perform

      expect(result).to include(
        dry_run: true, people_scanned: 3, people_to_change: 1, contacts_to_change: 1,
        conversations_to_change: 2, labels_to_write: 4, people_written: 0, people_failed: 0
      )
    end

    it 'writes nothing and dispatches nothing' do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)
      stamps = -> { [contact, first_conversation, second_conversation].map { |record| record.reload.updated_at } }

      expect { described_class.new(account_id: account.id).perform }
        .to not_change(ActsAsTaggableOn::Tagging, :count).and(not_change(&stamps))

      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
      expect(lists(contact, first_conversation, second_conversation)).to eq([%w[card], %w[channel], []])
    end
  end

  describe 'applying' do
    it 'gives the contact and every conversation of each person the union, quietly' do
      allow(Rails.configuration.dispatcher).to receive(:dispatch)

      expect { described_class.new(account_id: account.id, apply: true).perform }
        .not_to have_enqueued_job(Conversations::ActivityMessageJob)

      union = %w[card channel]
      expect(lists(contact, first_conversation, second_conversation)).to all(match_array(union))
      expect(lists(settled_contact, settled_conversation)).to all(eq(%w[settled]))
      expect(lists(card_only_contact)).to eq([%w[alone]])
      expect(Rails.configuration.dispatcher).not_to have_received(:dispatch)
    end

    it 'reports what it wrote and finds nothing left to do on a second run' do
      result = described_class.new(account_id: account.id, apply: true).perform
      again = described_class.new(account_id: account.id, apply: true).perform

      expect(result).to include(dry_run: false, people_to_change: 1, people_written: 1, people_failed: 0)
      expect(again).to include(people_scanned: 3, people_to_change: 0, people_written: 0)
    end

    it 'leaves another account alone' do
      other_account = create(:account)
      other_contact = create(:contact, account: other_account)
      other_conversation = create(:conversation, account: other_account, contact: other_contact)
      other_contact.update_labels(%w[other])

      described_class.new(account_id: account.id, apply: true).perform

      expect(lists(other_conversation)).to eq([[]])
    end

    it 'counts a person it could not write and goes on with the others' do
      allow(Labels::UnifiedAssignmentService).to receive(:unify).and_raise(ActiveRecord::RecordInvalid)

      result = described_class.new(account_id: account.id, apply: true).perform

      expect(result).to include(people_written: 0, people_failed: 1)
    end
  end

  describe 'the rake task onelink:labels:unify_person_union' do
    let(:task) { Rake::Task['onelink:labels:unify_person_union'] }

    before do
      Rails.application.load_tasks unless Rake::Task.task_defined?('onelink:labels:unify_person_union')
      task.reenable
      ENV['ACCOUNT_ID'] = account.id.to_s
    end

    after do
      ENV.delete('ACCOUNT_ID')
      ENV.delete('APPLY')
    end

    it 'is a dry run unless APPLY=1: it prints counts and writes nothing' do
      expect { task.invoke }.to output(/"dry_run": true.*"people_to_change": 1/m).to_stdout

      expect(lists(contact, first_conversation, second_conversation)).to eq([%w[card], %w[channel], []])
    end

    it 'writes with APPLY=1' do
      ENV['APPLY'] = '1'

      expect { task.invoke }.to output(/"dry_run": false.*"people_written": 1/m).to_stdout

      expect(lists(contact, first_conversation, second_conversation)).to all(match_array(%w[card channel]))
    end

    it 'prints no label, no name and no id of a person' do
      expect { task.invoke }.not_to output(/card|channel|settled|alone/).to_stdout
    end
  end
end
