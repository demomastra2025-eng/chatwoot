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

  # The text of an image is long (a lab page is 2-5 KB), and it must not push the dialogue out of the history.
  describe 'the text of images' do
    let(:budget) { described_class.new }

    it 'gives the newest image all it needs, up to the budget of the images' do
      expect(budget.image_text('a' * 5_000)).to eq('a' * 5_000)
    end

    it 'gives an older image what is left, cut at the end and marked as cut' do
      budget.image_text('a' * 5_000)

      older = budget.image_text('b' * 5_000)

      expect(older.bytesize).to be <= described_class::MAX_IMAGE_BYTES - 5_000
      expect(older).to start_with('b' * 100).and end_with(described_class::IMAGE_CUT_MARK)
    end

    it 'never spends more than the budget of the images in all' do
      total = Array.new(6) { budget.image_text('я' * 1_500) }.sum(&:bytesize)

      expect(total).to be <= described_class::MAX_IMAGE_BYTES
    end

    it 'cuts a multibyte text on a character, not in the middle of one' do
      budget.image_text('a') # leaves an odd number of bytes, so the cut falls inside a two-byte letter
      cut = budget.image_text('я' * 6_000)

      expect(cut).to be_valid_encoding
      expect(cut).not_to include("\uFFFD")
    end

    it 'gives nothing when too little is left to be worth a cut, so that the caller says the text is left out' do
      budget.image_text('a' * (described_class::MAX_IMAGE_BYTES - described_class::MIN_IMAGE_BYTES + 1))

      expect(budget.image_text('b' * 500)).to eq('')
    end

    it 'does not count against the dialogue: the message that holds the image text is kept with the text it brings' do
      dialogue = 'q' * (described_class::MAX_TEXT_BYTES - 100)
      image = budget.image_text('t' * 7_000)

      expect(budget.include_message?([{ type: 'text', text: dialogue }, { type: 'text', text: image }])).to be(true)
      # the next message still fits into what the dialogue has left
      expect(budget.include_message?('z' * 90)).to be(true)
      expect(budget.include_message?('z' * 90)).to be(false)
    end

    it 'counts only the image text of the message just built, not of an earlier one' do
      first = budget.image_text('t' * 4_000)
      budget.include_message?(first)
      budget.include_message?('x' * 15_000)

      expect(budget.include_message?('y' * 2_000)).to be(false)
    end

    it 'has a budget of its own apart from the documents' do
      expect(budget.document_text('d' * 10_000).bytesize).to eq(described_class::MAX_DOCUMENT_BYTES)
      expect(budget.image_text('i' * 3_000)).to eq('i' * 3_000)
    end
  end
end
