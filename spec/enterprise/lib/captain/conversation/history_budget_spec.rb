require 'rails_helper'

RSpec.describe Captain::Conversation::HistoryBudget do
  it 'keeps protected messages after the text budget is full' do
    budget = described_class.new
    expect(budget.include_message?('a' * described_class::MAX_TEXT_BYTES)).to be(true)
    expect(budget.include_message?('old')).to be(false)
    expect(budget.include_message?('latest customer request', protected: true)).to be(true)
  end

  it 'limits images and document text across a call' do
    budget = described_class.new
    expect(Array.new(3) { budget.include_image? }).to eq([true, true, false])
    expect(budget.document_text('x' * 10_000).bytesize).to eq(described_class::MAX_DOCUMENT_BYTES)
    expect(budget.document_text('new document')).to be_empty
  end
end
