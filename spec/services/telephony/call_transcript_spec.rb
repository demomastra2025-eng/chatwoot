# frozen_string_literal: true

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

  it 'parses compact array items and handles interval arrays for start_sec' do
    result = described_class.parse(
      '{"items":[[0,"op","Алло, клиника Әлия"],[[4,8],"cl","Сәлеметсіз бе, УЗИ бар ма?"]],' \
      '"summary":"Клиент спросил про УЗИ.","outcome":"consultation","topics":["УЗИ"]}'
    )

    expect(result['text']).to eq("[00:00] Сотрудник: Алло, клиника Әлия\n[00:04] Клиент: Сәлеметсіз бе, УЗИ бар ма?")
    expect(result['summary']).to eq('Клиент спросил про УЗИ.')
    expect(result['outcome']).to eq('consultation')
    expect(result['transcript_items'].map { |item| [item['start_sec'], item['speaker']] }).to eq([[0, 'operator'], [4, 'client']])
  end

  it 'accepts plain timestamped transcript lines' do
    result = described_class.parse("[00:02] Оператор: Добрый день\n[00:07] Клиент: Нужна запись")

    expect(result['transcript_items'].size).to eq(2)
    expect(result['text']).to include('[00:02] Сотрудник: Добрый день')
  end
end
