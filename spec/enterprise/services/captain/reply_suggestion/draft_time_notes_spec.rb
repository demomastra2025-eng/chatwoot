# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::ReplySuggestion::DraftTimeNotes do
  def notes(payload)
    described_class.new(payload)
  end

  it 'has nothing to say about a draft with no flagged time' do
    expect(notes({}).note).to be_nil
    expect(notes({}).meta).to eq({})
    expect(notes(nil).unverified).to eq([])
    expect(notes(unverified_times: [], misattributed_times: []).meta).to eq({})
  end

  it 'names the time that no read found, as before' do
    payload = { 'unverified_times' => ['19:00', ' ', 1930] }

    expect(notes(payload).unverified).to eq(%w[19:00 1930])
    expect(notes(payload).note).to eq(I18n.t('captain.reply_suggestion.reasons.unverified_times', times: '19:00, 1930'))
    expect(notes(payload).meta).to eq('unverified_times' => %w[19:00 1930])
  end

  # Suggestion eval 27.10 (c74-1233747): the free times of one gynecologist were given under the name of the other.
  it 'names the time given under the name of a specialist whose list does not hold it, with that name, after the other note' do
    payload = { unverified_times: ['19:00'],
                misattributed_times: [{ 'name' => 'Князова Жанат', 'time' => '11:00' }, { name: 'Турешева Акбаян', time: '10:30' },
                                      { 'name' => '', 'time' => '12:00' }, { 'name' => 'Без времени' }, 'garbage'] }

    expect(notes(payload).misattributed).to eq([{ 'name' => 'Князова Жанат', 'time' => '11:00' }, { 'name' => 'Турешева Акбаян', 'time' => '10:30' }])
    expect(notes(payload).note).to eq(
      [I18n.t('captain.reply_suggestion.reasons.unverified_times', times: '19:00'),
       I18n.t('captain.reply_suggestion.reasons.misattributed_times', times: '11:00 (Князова Жанат), 10:30 (Турешева Акбаян)')].join(' ')
    )
    expect(notes(payload).meta.keys).to eq(%w[unverified_times misattributed_times])
  end

  it 'has the note of a misattributed time in every language of the staff' do
    %i[ru kk en].each do |locale|
      expect(I18n.t('captain.reply_suggestion.reasons.misattributed_times', times: '11:00 (X)', locale: locale)).to include('11:00 (X)')
    end
  end
end
