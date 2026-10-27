# frozen_string_literal: true

require 'rails_helper'

# Suggestion eval 27.10 (c74-1233747): the free times of one gynecologist were given under the name of the other, and the check of the
# times (DraftTimes) passed, because both times were in the search. Every time that stands under a name must be on the list of that
# specialist.
RSpec.describe Captain::ReplySuggestion::DraftSpecialists do
  let(:cache_key) { Captain::Runtime::ToolWrapper::SUGGESTION_READ_CACHE_KEY }
  let(:two_gynecologists) do
    context_of(read({ days: [named_day(131, 'Князова Жанат', '09:00', '10:30'), named_day(120, 'Турешева Акбаян', '11:00', '12:30')] }))
  end

  def named_day(resource_id, name, *times)
    { resource_id: resource_id, name: name, date: '2026-10-30', times: times, more: 0 }
  end

  def read(result, tool: 'search_available_slots')
    { result: { success: true, message: JSON.generate(result) }, tool: tool }
  end

  def context_of(*reads)
    { cache_key => reads.each_with_index.to_h { |entry, index| ["digest-#{index}", entry] } }
  end

  def misattributed(draft, context = two_gynecologists)
    described_class.misattributed(draft: draft, context: context)
  end

  it 'names a time given under the name of the specialist whose list does not hold it, in any case form of the name' do
    draft = 'Свободно: у Князовой 09:00 и 11:00, у Турешевой 11:00 и 10:30.'

    expect(misattributed(draft)).to eq([{ 'name' => 'Князова Жанат', 'time' => '11:00' }, { 'name' => 'Турешева Акбаян', 'time' => '10:30' }])
  end

  it 'puts a time under the nearest name before it in a sentence that starts with a name, and after it in one that starts with a time' do
    name_first = "Князова Жанат — 09:00, 10:30\nТурешева Акбаян — 11:00, 12:30"
    time_first = 'В 11:00 свободна Турешева Акбаян, в 10:30 — Князова Жанат.'
    swapped = 'Свободно: Князова Жанат — 11:00, 12:30; Турешева Акбаян — 09:00.'

    expect(misattributed(name_first)).to eq([])
    expect(misattributed(time_first)).to eq([])
    expect(misattributed("Князова Жанат — 09:00\nТурешева Акбаян — 09:00")).to eq([{ 'name' => 'Турешева Акбаян', 'time' => '09:00' }])
    expect(misattributed(swapped)).to eq([{ 'name' => 'Князова Жанат', 'time' => '11:00' }, { 'name' => 'Князова Жанат', 'time' => '12:30' },
                                          { 'name' => 'Турешева Акбаян', 'time' => '09:00' }])
  end

  it 'leaves alone a sentence with no name, a name with its times in the next sentence, a bound and a time that no read lists' do
    expect(misattributed('Свободно в 11:00 и в 10:30.')).to eq([])
    expect(misattributed('Записать вас к Князовой? Свободно 11:00.')).to eq([])
    expect(misattributed('У Князовой нет окон до 12:30, свободно 09:00.')).to eq([])
    expect(misattributed('У Князовой свободно 19:00.')).to eq([])
    expect(misattributed('В 11:00 ждём вас, Князова Жанат.')).to eq([{ 'name' => 'Князова Жанат', 'time' => '11:00' }])
  end

  it 'leaves alone a time with no name on the side it stands under' do
    expect(misattributed('В 09:00 у Князовой, а ещё в 11:00.')).to eq([])
  end

  # Review of quality-fixes-1 (L1): the order of names and times was decided once per sentence, so the time that follows an «а» went to the
  # name before it.
  it 'reads a sentence clause by clause: a clause that starts with a name and a clause that starts with a time have their own order' do
    expect(misattributed('Князова Жанат в 09:00, а 11:00 у Турешевой Акбаян.')).to eq([])
    expect(misattributed('У Князовой 09:00, но 11:00 у Турешевой.')).to eq([])
    expect(misattributed('У Князовой 09:00, а у Турешевой 09:00.')).to eq([{ 'name' => 'Турешева Акбаян', 'time' => '09:00' }])
    expect(misattributed('Князова Жанат в 11:00, а 09:00 у Турешевой.'))
      .to eq([{ 'name' => 'Князова Жанат', 'time' => '11:00' }, { 'name' => 'Турешева Акбаян', 'time' => '09:00' }])
  end

  it 'does not take the name the draft addresses the patient with for a specialist' do
    gynecologists = context_of(read({ days: [named_day(131, 'Князова Мария', '09:00'), named_day(120, 'Турешева Акбаян', '11:00')] }))

    expect(misattributed('Мария, есть 11:00 у Турешевой.', gynecologists)).to eq([])
    expect(misattributed('Добрый день, Мария! У Турешевой 11:00.', gynecologists)).to eq([])
    expect(misattributed('Здравствуйте, Мария, 11:00 свободно у Турешевой.', gynecologists)).to eq([])
    # a name that a time follows at once lists the time under it
    expect(misattributed('Мария, 11:00; Акбаян, 09:00', gynecologists))
      .to eq([{ 'name' => 'Князова Мария', 'time' => '11:00' }, { 'name' => 'Турешева Акбаян', 'time' => '09:00' }])
  end

  it 'does not name the time of a booking the patient has, which the draft gives to say where the patient is booked' do
    booking = read({ appointments: [{ id: 5, status: 'scheduled', date: '30.10.2026', time: '11:00', doctor: 'Князова Жанат' }] },
                   tool: 'list_my_appointments')
    context = context_of(read({ days: [named_day(131, 'Князова Жанат', '09:00'), named_day(120, 'Турешева Акбаян', '11:00')] }), booking)

    expect(misattributed('Вы записаны к Князовой на 11:00. У Турешевой тоже есть 11:00.', context)).to eq([])
    expect(misattributed('Вы записаны к Князовой на 11:00. У Турешевой тоже есть 11:00.')).to eq([{ 'name' => 'Князова Жанат', 'time' => '11:00' }])
  end

  it 'leaves alone a name that fits two specialists, and a run that read no list of times' do
    alike = context_of(read({ days: [named_day(131, 'Жанат Князова', '09:00'), named_day(120, 'Жанат Турешева', '11:00')] }))

    expect(misattributed('Жанат свободна в 11:00.', alike)).to eq([])
    expect(misattributed('У Князовой 11:00.', alike)).to eq([{ 'name' => 'Жанат Князова', 'time' => '11:00' }])
    expect(misattributed('У Князовой 11:00.', {})).to eq([])
    expect(misattributed('', two_gynecologists)).to eq([])
  end

  # The suggestion eval 27.10 flagged three drafts and all three flags were wrong. Each draft below is one of them (the names and the
  # times are those of the clinic's calendar of that run).
  describe 'the drafts that the eval of 27.10 flagged by mistake' do
    # c43-1242656: «Жанаргүл» (a Kazakh letter) was no name of the catalog («Жанаргуль»), and the first four letters of «Жанат» matched it, so
    # the times of Ешимбаева were read under Князова.
    it 'reads a Kazakh letter in a name as the Russian one: «Жанаргүл» is «Жанаргуль», and never «Жанат»' do
      gynecologists = context_of(read({ days: [named_day(132, 'Бакирова Райхан', '09:00', '09:30', '10:30', '11:00', '11:30'),
                                               named_day(123, 'Ешимбаева Жанаргуль', '09:00', '09:30', '10:30', '11:30', '12:30'),
                                               named_day(131, 'Князова Жанат', '09:00', '10:00', '11:15', '12:15', '13:30')] }))
      draft = 'Сәлеметсіз бе! Ертең, 31 қазанда гинекологқа бос орындар бар: Бакирова Райхан — 09:00 немесе 10:30; ' \
              'Ешимбаева Жанаргүл — 09:30 немесе 12:30; Князова Жанат — 11:15. Қай уақыт ыңғайлы?'

      expect(misattributed(draft, gynecologists)).to eq([])
      expect(misattributed('Ешимбаева Жанаргүл — 11:15', gynecologists)).to eq([{ 'name' => 'Ешимбаева Жанаргуль', 'time' => '11:15' }])
      expect(misattributed('У Жанаргүл 09:30, у Жаната 11:15.', gynecologists)).to eq([])
    end

    # c43-1241622: the sentence went on after «15 000 ₸.» (a full stop after a sign is the end of a sentence), so the first name of the draft
    # was in the price sentence, and the times of the list after it were read under the name before them, not the name after them.
    it 'ends a sentence at a full stop after a sign like «₸», so a list of «в 09:00 у Иванова» reads its times under the names after them' do
      gynecologists = context_of(read({ days: [named_day(126, 'Амиркулова Анар', '11:00', '11:30', '12:15'),
                                               named_day(132, 'Бакирова Райхан', '09:00', '09:30', '10:30'),
                                               named_day(130, 'Шангараева Алия', '09:00', '10:30', '11:00')] }))
      draft = 'Первичный приём гинеколога стоит от 10 000 до 15 000 ₸: у большинства врачей — 10 000 ₸, у Шангараевой Алии Аблаевны — ' \
              '15 000 ₸. Ближайшие свободные окна: 31 октября в 09:00 у Бакировой Райхан (10 000 ₸), 31 октября в 11:00 у Амиркуловой ' \
              'Анар (10 000 ₸), 2 ноября в 09:00 у Шангараевой Алии Аблаевны (15 000 ₸).'

      expect(described_class.clauses_of('Стоит 15 000 ₸. Окна: в 09:00 у Ивановой')).to eq(['Стоит 15 000 ₸', 'Окна: в 09:00 у Ивановой'])
      expect(misattributed(draft, gynecologists)).to eq([])
      expect(misattributed(draft.sub('в 11:00 у Амиркуловой', 'в 09:00 у Амиркуловой'), gynecologists))
        .to eq([{ 'name' => 'Амиркулова Анар', 'time' => '09:00' }])
    end

    # c76-1226318: the initial «А.» of «Агабек А.» was read as the conjunction «а», which cut the list in two and put the times of Агабек
    # under the name after them.
    it 'reads the initial of a doctor as part of the name, never as the conjunction «а»' do
      days = [named_day(166, 'Жунусова Ж.', '08:10', '09:50', '12:00', '13:50', '15:50'),
              named_day(163, 'Агабек А.', '13:40', '14:50', '16:10', '17:20', '18:40'),
              named_day(167, 'Хаддадин Дани', '08:10', '09:20', '10:30', '11:40', '12:50')]
      otolaryngologists = context_of(read({ days: days }))
      draft = 'Здравствуйте! На сегодня есть свободные окна к детскому ЛОРу: Жунусова Ж. — 09:50, 12:00 или 15:50; ' \
              'Агабек А. — 13:40, 16:10 или 18:40; Хаддадин Дани — 09:20, 11:40 или 12:50.'

      expect(described_class.clauses_of('Агабек А. — 13:40, а 14:50 у Жунусовой')).to eq(['Агабек А. — 13:40,', '14:50 у Жунусовой'])
      expect(described_class.clauses_of('Агабек А. — 13:40; Хаддадин Дани — 09:20')).to eq(['Агабек А. — 13:40; Хаддадин Дани — 09:20'])
      expect(misattributed(draft, otolaryngologists)).to eq([])
      expect(misattributed(draft.sub('Агабек А. — 13:40', 'Агабек А. — 09:20'), otolaryngologists))
        .to eq([{ 'name' => 'Агабек А.', 'time' => '09:20' }])
    end
  end

  describe 'the words of a name' do
    it 'matches a word of the name as a whole, in any case, and never by its first letters' do
      people = { 1 => { name: 'Князова Жанат' }, 2 => { name: 'Ешимбаева Жанаргуль' }, 3 => { name: 'Хаддадин Дани' } }
      stems = people.transform_values { |person| described_class.name_stems(person[:name]) }

      expect(stems).to eq(1 => %w[князов жанат], 2 => %w[ешимбаев жанаргул], 3 => %w[хаддадин дани])
      forms = %w[Князова Князовой Князову Жанат Жаната Жанату]
      expect(forms.map { |word| described_class.stem_of(word) }).to eq(%w[князов князов князов жанат жанат жанат])
      expect(described_class.stem_of('Жанаргүл')).to eq(described_class.stem_of('Жанаргуль'))
      expect(described_class.stem_of('Жанаргүл')).not_to eq(described_class.stem_of('Жанат'))
      expect(described_class.stem_of('Данияр')).not_to eq(described_class.stem_of('Дани'))
    end
  end

  it 'knows a specialist of the catalog who has no free time listed' do
    catalog = read({ resources: [{ id: 128, name: 'Агабек Әлібек', specialty: 'ЛОР' }] }, tool: 'search_scheduling_resources')
    context = context_of(read({ days: [named_day(120, 'Турешева Акбаян', '11:00')] }), catalog)

    expect(misattributed('У Агабека свободно 11:00.', context)).to eq([{ 'name' => 'Агабек Әлібек', 'time' => '11:00' }])
  end
end
