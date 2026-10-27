# frozen_string_literal: true

require 'rails_helper'

# The text of `response` out of the pieces of JSON that the model streams.
RSpec.describe Captain::ReplySuggestion::DraftStream::FieldReader do
  subject(:reader) { described_class.new }

  let(:document) do
    {
      patient_language: 'ru', response: "Здравствуйте!\nПриём стоит \"8000\" тенге \\ 😀 {скобки} [тоже]", response_mode: 'reply',
      operator_note: '', reasoning: 'по прайсу', artifact_ids: %w[a1 b"2]
    }.to_json
  end
  let(:expected_text) { "Здравствуйте!\nПриём стоит \"8000\" тенге \\ 😀 {скобки} [тоже]" }

  def feed_in_pieces(text, size)
    text.chars.each_slice(size) { |piece| reader.feed(piece.join) }
  end

  it 'gives the text of the field, decoded, once the whole document is read' do
    reader.feed(document)

    expect(reader.text).to eq(expected_text)
    expect(reader.closed?).to be(true)
    expect(reader.mode).to eq('reply')
    expect(reader).to be_done
    expect(reader).not_to be_dead
  end

  it 'gives the same text whatever the size of the pieces, an escape cut in the middle included' do
    [1, 2, 3, 5, 7, 64].each do |size|
      piece_reader = described_class.new
      document.chars.each_slice(size) { |piece| piece_reader.feed(piece.join) }

      expect(piece_reader.text).to eq(expected_text), "pieces of #{size}"
      expect(piece_reader.mode).to eq('reply'), "pieces of #{size}"
    end
  end

  it 'grows while the field is written and is not closed until its closing quote' do
    reader.feed('{"patient_language":"ru","response":"Здравствуй')

    expect(reader.text).to eq('Здравствуй')
    expect(reader.closed?).to be(false)

    reader.feed('те!","response_mode":')

    expect(reader.text).to eq('Здравствуйте!')
    expect(reader.closed?).to be(true)
    expect(reader.mode).to be_nil
  end

  it 'reads a character that is written as a pair of escapes, also when the pair is cut' do
    reader.feed('{"response":"a\ud83d')
    expect(reader.text).to eq('a')

    reader.feed('\ude00bб')
    expect(reader.text).to eq('a😀bб')
  end

  it 'replaces a lone half of a pair instead of failing' do
    reader.feed('{"response":"a\ud83dz\ude00y"')

    expect(reader.text).to eq("a#{described_class::REPLACEMENT}z#{described_class::REPLACEMENT}y")
    expect(reader).not_to be_dead
  end

  it 'gives nothing for an empty response and reads the mode after it' do
    reader.feed('{"patient_language":"ru","response":"","response_mode":"human","operator_note":"нужен врач"}')

    expect(reader.text).to eq('')
    expect(reader.closed?).to be(true)
    expect(reader.mode).to eq('human')
  end

  it 'reads the mode when it is written before the text' do
    reader.feed('{"response_mode":"suppress","response":""}')

    expect(reader.mode).to eq('suppress')
    expect(reader).to be_done
  end

  it 'looks at the top-level keys only: the same words in a value or in a list are not the field' do
    reader.feed('{"reasoning":"\"response\":\"fake\"","artifact_ids":["response","{x}"],"nested":{"response":"inner"},"response":"real"}')

    expect(reader.text).to eq('real')
    expect(reader).to be_done
  end

  it 'skips values that are not strings, a null response included' do
    reader.feed('{"count":12.5,"flag":true,"nothing":null,"response":null,"response_mode":"reply"}')

    expect(reader.text).to eq('')
    expect(reader.closed?).to be(false)
    expect(reader.mode).to eq('reply')
    expect(reader).to be_done
  end

  it 'stops previewing when a tracked key repeats because the final parser may replace it' do
    reader.feed('{"response_mode":"reply","response":"first","response":"second"}')

    expect(reader).to be_dead
  end

  it 'stops previewing when the mode repeats, even if its second value is not a string' do
    reader.feed('{"response_mode":"reply","response":"first","response_mode":null}')

    expect(reader).to be_dead
  end

  it 'tolerates whitespace between the tokens' do
    feed_in_pieces(%({\n  "patient_language" : "ru" ,\n  "response" : "ок" \n}), 3)

    expect(reader.text).to eq('ок')
    expect(reader).to be_done
  end

  it 'ends the reading for good at something that is not JSON' do
    ['not json', '[1,2]', '{"response" "x"}', '{"response":"x" "y"}', '{"response":"bad \q escape"}', '{"response":"\u12G4"}'].each do |text|
      broken = described_class.new
      broken.feed(text)

      expect(broken).to be_dead, text
    end
  end

  it 'keeps what it had read when the document breaks, and reads nothing more' do
    reader.feed('{"response":"хорошо')
    reader.feed('"?')
    reader.feed(',"response_mode":"human"}')

    expect(reader).to be_dead
    expect(reader.text).to eq('хорошо')
    expect(reader.mode).to be_nil
  end

  it 'stops at the end of the document and ignores what comes after it' do
    reader.feed('{"response":"one"}{"response":"two"}')

    expect(reader.text).to eq('one')
    expect(reader).to be_done
  end

  it 'dies on a text that grows past the limit' do
    reader.feed(%({"response":"#{'a' * (described_class::MAX_TEXT_LENGTH + 1)}"}))

    expect(reader).to be_dead
  end

  it 'starts over after #reset' do
    reader.feed('{"response":"one","response_mode":"reply"}')
    reader.reset
    reader.feed('{"response":"two"')

    expect(reader.text).to eq('two')
    expect(reader.mode).to be_nil
    expect(reader).not_to be_done
  end
end
