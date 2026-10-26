# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Captain::PatientIntent do
  describe '.booking_change?' do
    it 'sees a request to cancel, move or make a visit in Russian' do
      [
        'Отмена завтра', 'Отмените, пожалуйста, запись на завтра', 'Хочу отменить приём', 'Можно перенести на пятницу?',
        'Перенесите на 15:00', 'Нужно перезаписаться', 'Не смогу прийти сегодня', 'Мы не сможем быть в 10:00', 'Не приду, заболела',
        'Запишите меня на завтра', 'Хочу записаться к ЛОРу', 'Записываемся на субботу', 'Давайте на другой день', 'Не успеваю к 14:00'
      ].each { |text| expect(described_class.booking_change?(text)).to be(true), text }
    end

    it 'sees a request to cancel, move or make a visit in Kazakh, with the Kazakh letters or typed without them' do
      [
        'Ертеңгі жазылуды болдырмаңыз', 'болдырмау керек еді', 'Уақытты ауыстырып беріңіз', 'ауыстырыңызшы', 'Келе алмаймын, ауырып қалдым',
        'келе алмаймыз', 'Бара алмаймын', 'Ертең келмеймін', 'Біз бармаймыз', 'Жазылғым келеді', 'Жазылайын деп едім', 'Жазып қойыңыз',
        'Иә, жазыңыз', 'Мені жазып беріңізші', 'Жазсаңыз болады ма?', 'Басқа уақытқа көшіріңіз', 'Жазылуды жойыңыз',
        'болдырмаңыз', 'келмеймін', 'ауыстырыныз', 'келе алмаймын'
      ].each { |text| expect(described_class.booking_change?(text)).to be(true), text }
    end

    it 'sees nothing in a thanks, a greeting, an emoji, a question about a price or a confirmation' do
      [
        'Спасибо!', 'Рахмет', 'Рақмет, жақсы', 'Здравствуйте', 'Сәлеметсіз бе', '👍', '💐🌷', 'Сколько стоит приём ЛОРа?', 'Хорошо, до свидания',
        'Жарайды', 'Иә, 14:00 болады', 'Ок', 'Какие есть врачи?', 'Қанша тұрады?', '', nil
      ].each { |text| expect(described_class.booking_change?(text)).to be(false), text.inspect }
    end

    it 'does not take the past tense of a thanks («записали», «жазып алдым») for a request' do
      expect(described_class.booking_change?('Спасибо, записали')).to be(false)
      expect(described_class.booking_change?('Рахмет, жазып алдым')).to be(false)
    end
  end

  describe '.human_request?' do
    it 'sees a request for a person, an operator or a call-back in Russian' do
      [
        'Соедините с оператором', 'Соедините меня с живым администратором немедленно!', 'Позовите администратора, хочу поговорить с человеком',
        'Дайте мне живого администратора, не хочу переписываться с ботом', 'Хочу поговорить с менеджером', 'Нужен живой человек',
        'Позвоните мне, пожалуйста', 'Перезвоните мне', 'Свяжитесь со мной', 'Переключите на сотрудника', 'Позовите руководителя',
        'Я говорю с роботом?', 'Это не бот?', 'Хочу связаться с директором'
      ].each { |text| expect(described_class.human_request?(text)).to be(true), text }
    end

    it 'sees a complaint, a refund or a legal matter in Russian' do
      [
        'Это жалоба на врача', 'Подам жалобу', 'У меня претензия', 'Верните деньги за приём', 'Мне так и не вернули деньги, нужен возврат',
        'Обратимся в суд', 'Напишу в прокуратуру', 'Передам дело юристу', 'Нужен адвокат', 'Я иду в полицию', 'Жду компенсацию'
      ].each { |text| expect(described_class.human_request?(text)).to be(true), text }
    end

    it 'sees a request for a person, a complaint, a refund or a legal matter in Kazakh, with or without the Kazakh letters' do
      [
        'Оператормен байланыстырыңыз', 'Операторды шақырыңыз', 'Тірі адаммен сөйлескім келеді', 'Әкімшіні шақырыңызшы', 'Менеджермен сөйлесейін',
        'Қызметкермен байланыстырыңыз', 'Басшымен сөйлесемін', 'Маған қоңырау шалыңыз', 'Маған хабарласыңыз', 'Шағым айтқым келеді',
        'ақшамды қайтарыңыз', 'Сотқа беремін', 'Заңгерге барамын', 'Ботпен емес, адаммен сөйлескім келеді', 'шагым жазам', 'акшамды кайтарыныз'
      ].each { |text| expect(described_class.human_request?(text)).to be(true), text }
    end

    # The eval of 26.10: the decision model sent this to staff, and the dialog never reached an agent.
    it 'sees nothing in a plain question about free times, a doctor, a price or a booking' do
      [
        'Есть окно сегодня или завтра для ребёнка к ЛОРу?', 'Есть окно на сегодня или завтра для ребёнка?',
        'Сколько стоит первичный приём ЛОРа?', 'Хочу записаться на УЗИ малого таза', 'Ертеңге ЛОР дәрігеріне жазылуға бола ма?',
        'Қанша тұрады?', 'Сәлеметсіз бе, ертең бос уақыт бар ма?', 'Давайте на 14:00, меня зовут Серик', 'Нас было 3 человека', 'Судороги у ребёнка',
        'Будем искать другое время', 'Здравствуйте!', '900101300123', '👍', '', nil
      ].each { |text| expect(described_class.human_request?(text)).to be(false), text.inspect }
    end
  end

  it 'compares the Kazakh letters folded to the Russian ones, in lower case, with one space between the words' do
    expect(described_class.folded('  ОТМЕНА   Қабылдау Ұ Ө Ү Һ Ә Ғ Ң І Ё ')).to eq('отмена кабылдау у о у х а г н и е')
  end
end
