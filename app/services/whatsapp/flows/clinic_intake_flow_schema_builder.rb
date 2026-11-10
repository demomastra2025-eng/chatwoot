# frozen_string_literal: true

class Whatsapp::Flows::ClinicIntakeFlowSchemaBuilder
  FLOW_JSON_VERSION = '6.0'

  ALIYA_OPTIONS = [
    {
      id: 'olymp_results',
      title: 'Результаты КДЛ Олимп',
      description: 'Выслать готовый PDF-бланк анализов в WhatsApp'
    },
    {
      id: 'smear_cytology',
      title: 'Мазок / цитология',
      description: 'Узнать готовность мазка, цитологии или гистологии'
    },
    {
      id: 'certificate',
      title: 'Справка / больничный',
      description: 'Оформление медицинской справки или больничного листа'
    },
    {
      id: 'quality_feedback',
      title: 'Обращение к руководству',
      description: 'Вопрос по качеству приёма, оплате или возврату средств'
    }
  ].freeze

  INTERMEDICAL_OPTIONS = [
    {
      id: 'lab_results',
      title: 'Результаты анализов',
      description: 'Узнать готовность и получить бланк анализов'
    },
    {
      id: 'form_075',
      title: 'Справка 075/у или 073/у',
      description: 'Оформление медицинских справок 075/у, 073/у, санаторной карты'
    },
    {
      id: 'sick_leave',
      title: 'Больничный лист',
      description: 'Открытие, продление или закрытие больничного листа'
    },
    {
      id: 'osms_referral',
      title: 'По ОСМС / ГОБМП',
      description: 'Приём, анализы или направление в рамках ОСМС / ГОБМП'
    },
    {
      id: 'quality_care',
      title: 'Служба заботы',
      description: 'Обращение по качеству сервиса, ожиданию или возврату'
    }
  ].freeze

  def self.request_type_title(request_type_id)
    return nil if request_type_id.blank?

    found = (ALIYA_OPTIONS + INTERMEDICAL_OPTIONS).find { |item| item[:id] == request_type_id.to_s }
    found ? found[:title] : request_type_id.to_s
  end

  def initialize(account: nil, preset: nil)
    @account = account
    @preset = Whatsapp::Flows::ClinicProfile.detect_preset(account, preset)
  end

  def build
    {
      version: FLOW_JSON_VERSION,
      screens: [intake_screen]
    }
  end

  def to_json(*_args)
    JSON.pretty_generate(build)
  end

  private

  attr_reader :account, :preset

  def intake_screen
    {
      id: 'INTAKE_STEP',
      title: screen_title,
      terminal: true,
      success: true,
      layout: {
        type: 'SingleColumnLayout',
        children: [
          {
            type: 'TextSubheading',
            text: screen_subheading
          },
          intake_form
        ]
      }
    }
  end

  def intake_form
    {
      type: 'Form',
      name: 'clinic_intake_form',
      children: [
        {
          'type' => 'Dropdown',
          'name' => 'request_type',
          'label' => 'Тип обращения',
          'required' => true,
          'data-source' => request_options
        },
        {
          'type' => 'TextInput',
          'name' => 'client_full_name',
          'input-type' => 'text',
          'label' => 'ФИО пациента',
          'required' => true,
          'max-chars' => 80
        },
        {
          'type' => 'TextInput',
          'name' => 'client_iin',
          'input-type' => 'text',
          'label' => 'ИИН (12 цифр)',
          'required' => true,
          'max-chars' => 12,
          'helper-text' => 'Для поиска карты и бланков анализов'
        },
        {
          'type' => 'TextInput',
          'name' => 'visit_date',
          'input-type' => 'text',
          'label' => 'Дата сдачи / приёма',
          'required' => false,
          'max-chars' => 30,
          'helper-text' => 'Например: вчера или 09.11.2026'
        },
        {
          'type' => 'TextArea',
          'name' => 'details',
          'label' => 'Детали запроса',
          'required' => false,
          'max-length' => 300,
          'helper-text' => details_helper
        },
        {
          'type' => 'Footer',
          'label' => 'Отправить заявку',
          'on-click-action' => {
            name: 'complete',
            payload: {
              onelink_flow_kind: 'clinic_intake',
              clinic_preset: preset,
              request_type: '${form.request_type}',
              client_full_name: '${form.client_full_name}',
              client_iin: '${form.client_iin}',
              visit_date: '${form.visit_date}',
              details: '${form.details}'
            }
          }
        }
      ]
    }
  end

  def screen_title
    case preset
    when 'aliya_center'
      'Анализы и справки'
    when 'intermedical'
      'Анализы, 075/у и ОСМС'
    else
      'Анализы и документы'
    end
  end

  def screen_subheading
    case preset
    when 'aliya_center'
      'МО «Әлия» • Запрос результатов КДЛ «Олимп», мазков и справок'
    when 'intermedical'
      'МЦ «Intermedical» • Результаты анализов, справки 075/у и ОСМС'
    else
      'Заполните данные пациента для получения анализов или справки'
    end
  end

  def details_helper
    case preset
    when 'aliya_center'
      'Укажите, какие анализы сдавались (ОАК, мазок, цитология и др.)'
    when 'intermedical'
      'Укажите названия анализов, вид справки (075/у) или врача'
    else
      'Укажите список анализов или комментарий'
    end
  end

  def request_options
    preset == 'aliya_center' ? ALIYA_OPTIONS : INTERMEDICAL_OPTIONS
  end
end
