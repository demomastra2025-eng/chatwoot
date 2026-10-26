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

    # Review of the cancellation guard: a thanks right after the clinic confirmed a cancellation or a move names the action as done.
    it 'does not take a thanks that names a cancellation, a move or a visit as done for a request' do
      [
        'Спасибо, что перенесли', 'Благодарю за перенос', 'Спасибо за отмену', 'Спасибо, что отменили запись', 'Спасибо, отменили',
        'Спасибо что передвинули', 'Спасибо, что сдвинули время', 'Большое спасибо, запись отменена', 'Спасибо! Перенесено на пятницу',
        'Благодарю, что перезаписали', 'Рақмет, жазылдым', 'Рахмет, жазылдық', 'Рақмет, ауыстырғаныңызға', 'Рахмет, ауыстырдыңыз',
        'Рақмет, көшіргеніңізге', 'Thanks for rescheduling, отменили'
      ].each { |text| expect(described_class.booking_change?(text)).to be(false), text }
    end

    it 'still takes a thanks that comes with a request for another cancellation, move or visit for one' do
      [
        'Спасибо, отмените запись на завтра', 'Спасибо, перенесите на пятницу', 'Спасибо! Запишите меня ещё на субботу',
        'Спасибо, а можно перенести на пятницу?', 'Спасибо. Отмена завтра', 'Благодарю, хочу записаться ещё к ЛОРу',
        'Спасибо, что перенесли. Теперь отмените вторую запись', 'Спасибо, что отменили. Запишите на пятницу', 'Спасибо, не смогу прийти',
        'Рахмет, ауыстырыңыз', 'Рақмет, болдырмаңыз', 'Рақмет, жазылайын', 'Рахмет, жазылғым келеді'
      ].each { |text| expect(described_class.booking_change?(text)).to be(true), text }
    end

    it 'does not leave a thanks unchecked: without a thanks word the past tense of the action is still a mention of it' do
      expect(described_class.booking_change?('Вы отменили мою запись?')).to be(true)
      expect(described_class.booking_change?('Запись перенесли, а мне никто не сказал')).to be(true)
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

    # Review of the human_handoff gate: wordings the first list missed, all read on the host.
    it 'sees a call asked in any form, the front desk, and a demand to stop writing in Russian' do
      [
        'Можете позвонить?', 'Можете мне позвонить?', 'Можете перезвонить?', 'Позвони мне', 'Позвоните в 5', 'Перезвони пожалуйста',
        'Жду звонка', 'Звоните мне после шести', 'Свяжите с регистратурой', 'Соедини меня с ресепшн', 'Хочу поговорить с кем-нибудь',
        'Хотела бы пообщаться с администратором клиники', 'Перестаньте мне писать', 'Не пишите мне больше', 'Хватит писать',
        'Отстаньте от меня', 'Переведите на живого сотрудника', 'Админа позовите', 'Нужен админ', 'Мне нужна регистратура'
      ].each { |text| expect(described_class.human_request?(text)).to be(true), text }
    end

    it 'sees a complaint, dissatisfaction and a demand for the money back in Russian in any form' do
      [
        'Хочу пожаловаться', 'Буду жаловаться', 'Я пожаловался', 'Хочу пожаловаться на врача', 'Я недоволен обслуживанием',
        'Мы очень недовольны', 'Возмутительное отношение', 'Безобразие какое-то', 'Мне нахамили в регистратуре', 'Отдайте мои деньги',
        'Отдайте деньги за приём', 'Где мои деньги?', 'Хочу свои деньги назад', 'Верните деньги', 'Подам в Минздрав'
      ].each { |text| expect(described_class.human_request?(text)).to be(true), text }
    end

    it 'sees a request for a person in English and for an administrator by its slang name in Kazakh' do
      [
        'operator', 'administrator', 'Please call me', 'I want to talk to a manager', 'Can I speak to a human?', 'Is this a bot?',
        'Give me a real person', 'I want to complain', 'I need a refund', 'Call me back',
        'Админге қосыңыз', 'Админмен сөйлесейін', 'Звондаңызшы', 'Қоңырау шалыңыз', 'Қоңыраулаңыз', 'Мен наразымын', 'Бас дәрігермен сөйлесейін'
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

    it 'sees nothing in a spine, a call the patient makes, a ringing in the ears, botox, a robotic operation or a welcome' do
      [
        'Болит позвоночник', 'Позвонок смещён, нужен невролог', 'Я позвоню позже', 'Звон в ушах уже неделю', 'Хочу сделать ботокс',
        'Роботизированная операция есть?', 'Добро пожаловать', 'Hello, is there a free time tomorrow?', 'Thank you', 'Сколько стоит ботулотоксин?'
      ].each { |text| expect(described_class.human_request?(text)).to be(false), text.inspect }
    end
  end

  it 'compares the Kazakh letters folded to the Russian ones, in lower case, with one space between the words' do
    expect(described_class.folded('  ОТМЕНА   Қабылдау Ұ Ө Ү Һ Ә Ғ Ң І Ё ')).to eq('отмена кабылдау у о у х а г н и е')
  end
end
