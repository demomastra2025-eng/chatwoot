require 'rails_helper'

RSpec.describe Captain::KnowledgeGrant, type: :model do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:document) { create(:captain_document, account: account, assistant: nil, visibility: :personal) }

  it 'rejects agents and materials belonging to different accounts' do
    grant = described_class.new(account: account, assistant: create(:captain_assistant), knowledge_record: document)
    expect(grant).not_to be_valid
    expect(grant.errors[:assistant]).to include('must belong to the same account')

    grant = described_class.new(account: account, assistant: assistant, knowledge_record: create(:captain_document))
    expect(grant).not_to be_valid
    expect(grant.errors[:knowledge_record]).to include('must belong to the same account')
  end

  it 'only accepts knowledge material types' do
    grant = described_class.new(account: account, assistant: assistant, knowledge_record: create(:user))

    expect(grant).not_to be_valid
    expect(grant.errors[:knowledge_record_type]).to be_present
  end

  it 'marks a direct grant as restricted before it can outlive the selected agent' do
    grant = described_class.create!(account: account, assistant: assistant, knowledge_record: document)
    expect(document.reload).to be_restricted_to_assistants
    grant.destroy!

    expect(Captain::Document.visible_to_assistant(nil)).not_to include(document)
  end
end
