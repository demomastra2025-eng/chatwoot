# frozen_string_literal: true

module Whatsapp::Flows::BookingFlowCopy # rubocop:disable Metrics/ModuleLength
  SUPPORTED_LOCALES = %w[ru kk en].freeze
  DEFAULT_LOCALE = 'ru'

  STRINGS = {
    'ru' => {
      flow_default_name: 'Онлайн-запись',
      booking_screen_title: 'Онлайн-запись',
      slot_screen_title: 'Выбор времени',
      details_screen_title: 'Ваши данные',
      service_label: 'Услуга',
      specialist_label: 'Специалист',
      any_specialist: 'Любой свободный специалист',
      date_label: 'Дата',
      slot_label: 'Свободное время',
      choose_time_cta: 'Выбрать время',
      next_cta: 'Далее',
      confirm_cta: 'Записаться',
      default_message_cta: 'Записаться',
      default_message_body: 'Выберите удобную услугу, специалиста и время прямо в форме ниже.',
      visit_reason_label: 'Повод обращения',
      first_name_label: 'Имя',
      last_name_label: 'Фамилия',
      middle_name_label: 'Отчество',
      phone_label: 'Телефон',
      birth_date_label: 'Дата рождения',
      birth_date_helper: 'Формат: ДД.ММ.ГГГГ или ГГГГ-ММ-ДД',
      iin_label: 'ИИН (12 цифр)',
      iin_helper: 'Введите 12 цифр ИИН',
      notes_label: 'Комментарий',
      duration_min_short: 'мин',
      flow_expired_error: 'Форма записи устарела. Закройте её и запросите актуальную форму в чате.',
      no_specialists_error: 'Сейчас нет доступных специалистов для онлайн-записи.',
      no_slots_on_date_with_next: 'На %<date>s нет свободного времени. Ближайшая доступная дата: %<next_date>s.',
      no_slots_any_date: 'К сожалению, на ближайшие дни свободного времени нет. Выберите другого специалиста.',
      slot_required_error: 'Пожалуйста, выберите удобное время.',
      slot_taken_error: 'Выбранное время только что заняли. Вернитесь назад и выберите другое время.',
      first_name_required: 'Пожалуйста, укажите имя.',
      last_name_required: 'Пожалуйста, укажите фамилию.',
      middle_name_required: 'Пожалуйста, укажите отчество.',
      phone_required: 'Пожалуйста, укажите корректный номер телефона.',
      kz_phone_required: 'Укажите казахстанский номер телефона в формате +77XXXXXXXXX.',
      birth_date_required: 'Укажите дату рождения в формате ДД.ММ.ГГГГ.',
      birth_date_invalid: 'Проверьте дату рождения (формат ДД.ММ.ГГГГ).',
      iin_required: 'Пожалуйста, укажите ИИН (12 цифр).',
      iin_invalid: 'Проверьте ИИН: должно быть 12 цифр с верной контрольной суммой.',
      weekdays: %w[Вс Пн Вт Ср Чт Пт Сб],
      months: %w[янв фев мар апр мая июн июл авг сен окт ноя дек]
    },
    'kk' => {
      flow_default_name: 'Онлайн жазылу',
      booking_screen_title: 'Онлайн жазылу',
      slot_screen_title: 'Уақытты таңдау',
      details_screen_title: 'Деректеріңіз',
      service_label: 'Қызмет',
      specialist_label: 'Маман',
      any_specialist: 'Кез келген бос маман',
      date_label: 'Күні',
      slot_label: 'Бос уақыт',
      choose_time_cta: 'Уақытты таңдау',
      next_cta: 'Келесі',
      confirm_cta: 'Жазылу',
      default_message_cta: 'Жазылу',
      default_message_body: 'Төмендегі формадан өзіңізге ыңғайлы қызметті, маманды және уақытты таңдаңыз.',
      visit_reason_label: 'Жүгіну себебі',
      first_name_label: 'Аты',
      last_name_label: 'Тегі',
      middle_name_label: 'Әкесінің аты',
      phone_label: 'Телефон нөмірі',
      birth_date_label: 'Туған күні',
      birth_date_helper: 'Форматын енгізіңіз: КК.АА.ЖЖЖЖ',
      iin_label: 'ЖСН (12 цифр)',
      iin_helper: '12 цифрлы ЖСН енгізіңіз',
      notes_label: 'Түсініктеме',
      duration_min_short: 'мин',
      flow_expired_error: 'Жазылу формасы ескірді. Оны жауып, чаттан жаңа форманы сұраңыз.',
      no_specialists_error: 'Қазіргі уақытта онлайн жазылуға қолжетімді мамандар жоқ.',
      no_slots_on_date_with_next: '%<date>s күні бос уақыт жоқ. Ең жақын бос күн: %<next_date>s.',
      no_slots_any_date: 'Жақын күндері бос уақыт жоқ. Басқа маманды таңдап көріңіз.',
      slot_required_error: 'Өзіңізге ыңғайлы уақытты таңдаңыз.',
      slot_taken_error: 'Таңдалған уақыт бос емес. Артқа қайтып, басқа уақытты таңдаңыз.',
      first_name_required: 'Атыңызды енгізіңіз.',
      last_name_required: 'Тегіңізді енгізіңіз.',
      middle_name_required: 'Әкеңіздің атын енгізіңіз.',
      phone_required: 'Дұрыс телефон нөмірін енгізіңіз.',
      kz_phone_required: 'Қазақстандық телефон нөмірін +77XXXXXXXXX форматында енгізіңіз.',
      birth_date_required: 'Туған күніңізді КК.АА.ЖЖЖЖ форматында енгізіңіз.',
      birth_date_invalid: 'Туған күніңізді тексеріңіз (КК.АА.ЖЖЖЖ).',
      iin_required: '12 цифрлы ЖСН енгізіңіз.',
      iin_invalid: 'ЖСН қате: 12 цифрды тексеріп қайта енгізіңіз.',
      weekdays: %w[Жс Дс Сс Ср Бс Жм Сб],
      months: %w[қаң ақп нау сәу мам мау шіл там қыр қаз қар жел]
    },
    'en' => {
      flow_default_name: 'Online Booking',
      booking_screen_title: 'Online Booking',
      slot_screen_title: 'Select Time',
      details_screen_title: 'Your Details',
      service_label: 'Service',
      specialist_label: 'Specialist',
      any_specialist: 'Any available specialist',
      date_label: 'Date',
      slot_label: 'Available time',
      choose_time_cta: 'Choose time',
      next_cta: 'Continue',
      confirm_cta: 'Confirm booking',
      default_message_cta: 'Book now',
      default_message_body: 'Choose a service, specialist, and convenient time in the form below.',
      visit_reason_label: 'Visit reason',
      first_name_label: 'First name',
      last_name_label: 'Last name',
      middle_name_label: 'Middle name',
      phone_label: 'Phone number',
      birth_date_label: 'Date of birth',
      birth_date_helper: 'Format: YYYY-MM-DD or DD.MM.YYYY',
      iin_label: 'IIN (12 digits)',
      iin_helper: 'Enter 12-digit IIN',
      notes_label: 'Notes',
      duration_min_short: 'min',
      flow_expired_error: 'This booking form has expired. Please close it and request a new link in chat.',
      no_specialists_error: 'No specialists are currently available for online booking.',
      no_slots_on_date_with_next: 'No free slots on %<date>s. Nearest available date: %<next_date>s.',
      no_slots_any_date: 'No available time slots in the upcoming days. Please choose another specialist.',
      slot_required_error: 'Please select an available time slot.',
      slot_taken_error: 'That time slot was just taken. Please go back and select another time.',
      first_name_required: 'Please enter your first name.',
      last_name_required: 'Please enter your last name.',
      middle_name_required: 'Please enter your middle name.',
      phone_required: 'Please enter a valid phone number.',
      kz_phone_required: 'Please enter a Kazakhstan phone number (+77XXXXXXXXX).',
      birth_date_required: 'Please enter your date of birth (YYYY-MM-DD).',
      birth_date_invalid: 'Please enter a valid calendar date of birth.',
      iin_required: 'Please enter your 12-digit IIN.',
      iin_invalid: 'Invalid IIN: please check all 12 digits.',
      weekdays: %w[Sun Mon Tue Wed Thu Fri Sat],
      months: %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec]
    }
  }.freeze

  module_function

  def normalize_locale(raw_locale, account: nil)
    candidate = raw_locale.to_s.strip.downcase.split(/[-_]/).first
    return candidate if SUPPORTED_LOCALES.include?(candidate)

    account_lang = Array(account&.settings.to_h['client_languages']).first.to_s.downcase.split(/[-_]/).first
    return account_lang if SUPPORTED_LOCALES.include?(account_lang)

    DEFAULT_LOCALE
  end

  def for_locale(raw_locale, account: nil)
    STRINGS.fetch(normalize_locale(raw_locale, account: account))
  end

  def format_date(date, locale:)
    copy = STRINGS.fetch(normalize_locale(locale))
    weekday = copy[:weekdays][date.wday]
    month = copy[:months][date.month - 1]
    "#{weekday}, #{date.day} #{month}"
  end
end
