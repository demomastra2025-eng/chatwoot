require 'rails_helper'

RSpec.describe Telephony::CallTranscript do
  it 'parses role-prefixed lines and keeps the summary separate' do
    result = described_class.parse(
      '{"transcript_items":[{"speaker":"operator","start_sec":2,"text":"Добрый день"},' \
      '{"speaker":"client","timestamp":"00:07","text":"Нужна запись"}],' \
      '"summary":"Пациент запросил запись.","outcome":"booked","topics":["запись"]}'
    )

    expect(result['text']).to eq("[00:02] Сотрудник: Добрый день\n[00:07] Клиент: Нужна запись")
    expect(result['summary']).to eq('Пациент запросил запись.')
    expect(result['transcript_items'].map { |item| item['speaker'] }).to eq(%w[operator client])
  end

  it 'accepts plain timestamped transcript lines' do
    result = described_class.parse("[00:02] Оператор: Добрый день\n[00:07] Клиент: Нужна запись")

    expect(result['transcript_items'].size).to eq(2)
    expect(result['text']).to include('[00:02] Сотрудник: Добрый день')
  end
end
