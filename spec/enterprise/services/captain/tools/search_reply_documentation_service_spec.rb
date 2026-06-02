require 'rails_helper'

RSpec.describe Captain::Tools::SearchReplyDocumentationService do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:other_assistant) { create(:captain_assistant, account: account) }

  def scoped_response_ids(service)
    service.send(:scoped_responses).pluck(:id)
  end

  it 'shares general entries across assistants and hides other assistants personal entries' do
    own_personal = create(
      :captain_assistant_response,
      account: account,
      assistant: assistant,
      answer: 'Own personal answer',
      visibility: :personal,
      status: :approved
    )
    shared_general = create(
      :captain_assistant_response,
      account: account,
      assistant: other_assistant,
      answer: 'Shared general answer',
      visibility: :general,
      status: :approved
    )
    hidden_personal = create(
      :captain_assistant_response,
      account: account,
      assistant: other_assistant,
      answer: 'Hidden personal answer',
      visibility: :personal,
      status: :approved
    )

    service = described_class.new(account: account, assistant: assistant)

    expect(scoped_response_ids(service)).to contain_exactly(own_personal.id, shared_general.id)
    expect(scoped_response_ids(service)).not_to include(hidden_personal.id)
  end

  it 'limits assistant-less lookups to general entries only' do
    general_entry = create(
      :captain_assistant_response,
      account: account,
      assistant: assistant,
      answer: 'General answer',
      visibility: :general,
      status: :approved
    )
    personal_entry = create(
      :captain_assistant_response,
      account: account,
      assistant: assistant,
      answer: 'Personal answer',
      visibility: :personal,
      status: :approved
    )

    service = described_class.new(account: account, assistant: nil)

    expect(scoped_response_ids(service)).to contain_exactly(general_entry.id)
    expect(scoped_response_ids(service)).not_to include(personal_entry.id)
  end

  it 'runs semantic search on the visibility-scoped response relation' do
    service = described_class.new(account: account, assistant: assistant)
    scoped_relation = service.send(:scoped_responses)

    allow(service).to receive(:scoped_responses).and_return(scoped_relation)
    allow(scoped_relation).to receive(:search).and_return(scoped_relation)

    expect(service.send(:search_responses, 'visibilityscope')).to eq(scoped_relation)
    expect(scoped_relation).to have_received(:search).with('visibilityscope', account_id: account.id)
  end
end
