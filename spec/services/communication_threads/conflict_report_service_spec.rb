require 'rails_helper'

RSpec.describe CommunicationThreads::ConflictReportService do
  let(:account) { create(:account).tap { |record| record.enable_features!('communication_threads') } }

  it 'reports routing mismatches without changing records' do
    contact = create(:contact, account: account)
    owner = create(:user, account: account)
    conversation = create(:conversation, account: account, contact: contact)
    thread = conversation.reload.communication_thread
    # Build an intentionally inconsistent persisted state for a read-only detector.
    # rubocop:disable Rails/SkipsModelValidations
    contact.update_column(:owner_id, owner.id)
    conversation.update_columns(assignee_id: nil, team_id: nil)
    thread.update_columns(assignee_id: nil, team_id: create(:team, account: account).id)
    # rubocop:enable Rails/SkipsModelValidations

    result = described_class.new(account_id: account.id).perform

    expect(result[:duplicate_contact_thread_groups]).to include(count: 0, sample: [])
    expect(result[:contact_thread_owner_mismatches][:count]).to eq(1)
    expect(result[:contact_conversation_owner_mismatches][:count]).to eq(1)
    expect(result[:thread_projection_routing_mismatches][:count]).to eq(1)
    expect(thread.reload).to be_persisted
    expect(contact.reload.owner_id).to eq(owner.id)
  end
end
