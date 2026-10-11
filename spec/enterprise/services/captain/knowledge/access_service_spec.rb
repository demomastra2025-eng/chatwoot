require 'rails_helper'

RSpec.describe Captain::Knowledge::AccessService do
  let(:account) { create(:account) }
  let(:parent) { create(:captain_assistant, account: account) }
  let(:converted) { create(:captain_assistant, account: account) }
  let(:unrelated) { create(:captain_assistant, account: account) }

  it 'grants a converted agent its parent personal materials without changing workspace visibility' do
    document = create(:captain_document, account: account, assistant: parent, visibility: :personal)
    faq = create(:captain_assistant_response, account: account, assistant: parent, visibility: :personal)
    granted = create(:captain_document, account: account, assistant: unrelated, visibility: :personal,
                                       allowed_assistant_ids: [parent.id])
    general = create(:captain_document, account: account, assistant: nil, visibility: :general)
    legacy = create(:captain_document, account: account, assistant: nil, visibility: :personal)
    other_private = create(:captain_document, account: account, assistant: unrelated, visibility: :personal)

    2.times { described_class.inherit_access!(from_assistant: parent, to_assistant: converted) }

    expect(Captain::Document.visible_to_assistant(converted.id)).to include(document, granted, general, legacy)
    expect(Captain::Document.visible_to_assistant(converted.id)).not_to include(other_private)
    expect(Captain::AssistantResponse.visible_to_assistant(converted.id)).to include(faq)
    expect(Captain::Document.visible_to_assistant(unrelated.id)).not_to include(document)
    expect(document.reload).to be_visibility_personal
    expect(document.knowledge_grants.where(assistant: converted).count).to eq(1)
    expect(general.knowledge_grants).to be_empty
    expect(legacy.knowledge_grants).to be_empty
  end

  it 'rejects cross-account inheritance' do
    expect do
      described_class.inherit_access!(from_assistant: parent, to_assistant: create(:captain_assistant))
    end.to raise_error(ArgumentError, 'Knowledge access can only be inherited within the same account')
  end

  it 'preserves shared personal material and its generated FAQ when the owner is deleted' do
    document = create(:captain_document, account: account, assistant: parent, visibility: :personal,
                                        allowed_assistant_ids: [converted.id])
    faq = create(:captain_assistant_response, account: account, assistant: parent, documentable: document, visibility: :personal)
    private_faq = create(:captain_assistant_response, account: account, assistant: parent, visibility: :personal)

    parent.destroy!

    expect(document.reload.assistant_id).to eq(converted.id)
    expect(document).to be_visibility_personal
    expect(faq.reload.assistant_id).to eq(converted.id)
    expect(Captain::Document.visible_to_assistant(converted.id)).to include(document)
    expect(Captain::AssistantResponse.visible_to_assistant(converted.id)).to include(faq)
    expect(Captain::Document.visible_to_assistant(unrelated.id)).not_to include(document)
    expect(Captain::AssistantResponse.exists?(private_faq.id)).to be false
  end

  it 'deletes an explicitly owner-only FAQ without sharing it with the remaining source owner' do
    document = create(:captain_document, account: account, assistant: parent, visibility: :personal,
                                        allowed_assistant_ids: [converted.id])
    faq = create(:captain_assistant_response, account: account, assistant: parent, documentable: document,
                                            visibility: :personal, allowed_assistant_ids: [parent.id])

    expect(Captain::AssistantResponse.visible_to_assistant(parent.id)).to include(faq)
    expect(Captain::AssistantResponse.visible_to_assistant(converted.id)).not_to include(faq)

    parent.destroy!

    expect(document.reload.assistant_id).to eq(converted.id)
    expect(Captain::AssistantResponse.exists?(faq.id)).to be false
  end

  it 'retains only the explicitly selected FAQ agents after its owner is deleted' do
    document = create(:captain_document, account: account, assistant: parent, visibility: :personal,
                                        allowed_assistant_ids: [converted.id, unrelated.id])
    faq = create(:captain_assistant_response, account: account, assistant: parent, documentable: document,
                                            visibility: :personal, allowed_assistant_ids: [parent.id, converted.id])

    parent.destroy!

    expect(document.reload.allowed_assistant_ids).to match_array([converted.id, unrelated.id])
    expect(faq.reload).to have_attributes(assistant_id: converted.id, restricted_to_assistants: true)
    expect(faq.allowed_assistant_ids).to eq([converted.id])
    expect(Captain::AssistantResponse.visible_to_assistant(converted.id)).to include(faq)
    expect(Captain::AssistantResponse.visible_to_assistant(unrelated.id)).not_to include(faq)
  end

  it 'does not broaden legacy private FAQs attached to workspace or differently owned sources' do
    workspace_source = create(:captain_document, account: account, assistant: nil, visibility: :personal)
    general_source = create(:captain_document, account: account, assistant: unrelated, visibility: :general)
    faqs = [workspace_source, general_source].map do |document|
      create(:captain_assistant_response, account: account, assistant: parent, documentable: document, visibility: :personal)
    end

    expect(faqs).to all(have_attributes(restricted_to_assistants: false))
    expect(Captain::AssistantResponse.visible_to_assistant(parent.id)).to include(*faqs)
    expect(Captain::AssistantResponse.visible_to_assistant(converted.id)).not_to include(*faqs)
    expect(Captain::AssistantResponse.visible_to_assistant(unrelated.id)).not_to include(*faqs)

    parent.destroy!

    expect(Captain::Document.exists?(workspace_source.id)).to be true
    expect(Captain::Document.exists?(general_source.id)).to be true
    expect(Captain::AssistantResponse.where(id: faqs.map(&:id))).to be_empty
  end

  it 'changes the actor fingerprint when its grants are revoked' do
    document = create(:captain_document, account: account, assistant: parent, visibility: :personal,
                                        allowed_assistant_ids: [converted.id])
    original = described_class.fingerprint(account: account, assistant: converted)
    document.knowledge_grants.where(assistant: converted).destroy_all

    expect(described_class.fingerprint(account: account, assistant: converted)).not_to eq(original)
    expect(described_class.fingerprint(account: account, assistant: parent)).not_to eq(original)
  end
end
