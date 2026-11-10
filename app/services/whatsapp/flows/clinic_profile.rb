# frozen_string_literal: true

module Whatsapp::Flows::ClinicProfile
  PRESETS = %w[default aliya_center intermedical].freeze

  ALIYA_VISIT_REASONS = [
    {
      id: 'gynecology',
      title: 'Приём по гинекологии',
      description: 'Консультация, осмотр, лечение у акушера-гинеколога'
    },
    {
      id: 'pregnancy',
      title: 'По беременности',
      description: 'Укажите срок (недель) и наличие УЗИ в комментарии'
    },
    {
      id: 'screening',
      title: 'Скрининг / УЗИ бер.',
      description: 'Скрининг I, II, III триместра, допплер, КТГ плода'
    },
    {
      id: 'ultrasound_gyn',
      title: 'УЗИ малого таза',
      description: 'Гинекологическое УЗИ, фолликулометрия, цервикометрия'
    },
    {
      id: 'ultrasound_other',
      title: 'УЗИ других органов',
      description: 'Молочные железы, щитовидная, ОБП, почки, сосуды'
    },
    {
      id: 'specialist',
      title: 'Другой специалист',
      description: 'Эндокринолог, невролог, генетик, терапевт'
    }
  ].freeze

  INTERMEDICAL_VISIT_REASONS = [
    {
      id: 'adult_paid',
      title: 'Взрослый (18+)',
      description: 'Платный приём врача для взрослых с 18 лет'
    },
    {
      id: 'child_paid',
      title: 'Ребёнок (0–17 лет)',
      description: 'Укажите точный возраст ребёнка в комментарии'
    },
    {
      id: 'diagnostics',
      title: 'УЗИ / МРТ / КТ / ФГДС',
      description: 'УЗИ (каб. 105), МРТ, КТ, рентген, ФГДС (натощак)'
    },
    {
      id: 'osms_gobmp',
      title: 'По ОСМС / ГОБМП',
      description: 'Приём или обследование по направлению ОСМС'
    },
    {
      id: 'physiotherapy',
      title: 'Физио / процедуры',
      description: 'Физиокабинет, лазерная терапия, ЭКГ, Холтер, СМАД'
    }
  ].freeze

  module_function

  def detect_preset(account, explicit_preset = nil)
    cleaned = explicit_preset.to_s.strip.downcase
    return cleaned if PRESETS.include?(cleaned) && cleaned != 'default'

    saved = account&.settings.to_h['clinic_flow_preset'].to_s.strip.downcase
    return saved if PRESETS.include?(saved) && saved != 'default'

    name = account&.name.to_s
    return 'aliya_center' if name.match?(/әлия|алия|aliya/i)
    return 'intermedical' if name.match?(/intermedical|интермедикал|талғар|талгар/i)

    PRESETS.include?(cleaned) ? cleaned : 'default'
  end

  def config_for(account: nil, preset: nil)
    resolved = detect_preset(account, preset)
    case resolved
    when 'aliya_center'
      {
        preset: 'aliya_center',
        clinic_title: 'МО «Әлия»',
        flow_default_name: 'Запись на приём — МО Әлия',
        intake_flow_default_name: 'Анализы Олимп и справки — МО Әлия',
        specialist_label: 'Врач / кабинет УЗИ',
        service_label: 'Услуга / вид УЗИ',
        confirm_cta: 'Подтвердить запись',
        show_visit_reason: true,
        visit_reasons: ALIYA_VISIT_REASONS,
        default_visit_reason: 'gynecology',
        force_show_iin: true,
        force_show_birth_date: false,
        notes_helper: 'Для беременных: укажите срок (нед.) и есть ли УЗИ'
      }
    when 'intermedical'
      {
        preset: 'intermedical',
        clinic_title: 'МЦ «Intermedical»',
        flow_default_name: 'Запись на приём — Intermedical',
        intake_flow_default_name: 'Анализы, 075/у и ОСМС — Intermedical',
        specialist_label: 'Врач / кабинет',
        service_label: 'Услуга / диагностика',
        confirm_cta: 'Подтвердить запись',
        show_visit_reason: true,
        visit_reasons: INTERMEDICAL_VISIT_REASONS,
        default_visit_reason: 'adult_paid',
        force_show_iin: true,
        force_show_birth_date: true,
        notes_helper: 'Для детей укажите возраст. УЗИ ОБП и ФГДС — натощак'
      }
    else
      {
        preset: 'default',
        clinic_title: account&.name.to_s.presence || 'Клиника',
        flow_default_name: nil,
        intake_flow_default_name: 'Запрос анализов и справок',
        specialist_label: nil,
        service_label: nil,
        confirm_cta: nil,
        show_visit_reason: false,
        visit_reasons: [],
        default_visit_reason: '',
        force_show_iin: false,
        force_show_birth_date: false,
        notes_helper: nil
      }
    end
  end

  def visit_reason_title(_preset_or_account, reason_id)
    return nil if reason_id.blank?

    all_reasons = ALIYA_VISIT_REASONS + INTERMEDICAL_VISIT_REASONS
    found = all_reasons.find { |item| item[:id] == reason_id.to_s }
    found ? found[:title] : reason_id.to_s
  end
end
