class Integrations::Medelement::SampleShapeReport
  def initialize(records:, doctors:, today:)
    @records = records
    @doctors = doctors
    @today = today
  end

  def render
    sections = [header, observed_contract, fields('Поля врача', doctor_rows),
                fields('Поля строки расписания', timetable_rows), day_section, doctor_section, timing_section]
    "#{sections.join("\n\n")}\n"
  end

  private

  attr_reader :records, :doctors, :today

  def header
    cabinet_count = doctor_rows.flat_map { |doctor| cabinet_codes(doctor) }.uniq.size
    selected_cabinet_count = doctors.flat_map { |doctor| cabinet_codes(doctor) }.uniq.size
    [
      '# Формы ответов MedElement',
      "Врачей в ответе: #{doctor_rows.size}; выбрано: #{doctors.size}; " \
      "кабинетов в ответе: #{cabinet_count}; у выбранных врачей: #{selected_cabinet_count}.",
      'Данные в samples.json уже обезличены. Код кабинета заменён стабильным коротким хешем.'
    ].join("\n")
  end

  def observed_contract
    [
      '## Подтверждённые формы API (тестовая организация, 07.10.2026)',
      '- get_specialists: объект с ключами-кодами врачей; specialistCode может быть числом больше точного диапазона JavaScript. ' \
        'isSchedulePublished наблюдался как число 1; случай 0 не проверен. Нет признака полноты, отключения или пагинации.',
      '- get_timetable: GET с date[0], date[1] (включительно) и одним specialistCode. Без кода врача получен HTTP 400. ' \
        'Рабочие интервалы наблюдались на +90 дней.',
      '- W: timetable содержит рабочие интервалы; specialistWorkingHours — объект со start, end, ' \
        'start_lunch, end_lunch и time_off. clinicWorkingHours — объект start/end.',
      '- D: timetable пуст, specialistWorkingHours равен строке "day off". ' \
        'Синхронизация подтверждает выходной после двух наблюдений подряд.',
      '- P: timetable пуст, specialistWorkingHours — объект часов. Это непроверенный день, не выходной.',
      '- Наблюдался end раньше start (08:00–00:00) при clinicWorkingHours 00:00–00:00; ' \
        'его нельзя трактовать как выходной или отпуск.',
      '- working=false означает нерабочий интервал, не запись пациента; time_off — интервалы отсутствия, ' \
        'start_lunch/end_lunch — обед. by_update_date относится к приёмам, не к изменениям расписания.',
      '- Лимит RPS и Retry-After не задокументированы; единичный HTTP 429 не воспроизведён.'
    ].join("\n")
  end

  def doctor_rows
    record = records.find { |row| row['operation'] == 'specialists' && row['status_class'] == '2xx' }
    Array(record&.dig('body'))
  end

  def cabinet_codes(doctor)
    Array(doctor['cabinets'].presence || doctor['cabinetCodes']).filter_map do |cabinet|
      cabinet.is_a?(Hash) ? cabinet['companyCabinetCode'] || cabinet['cabinetCode'] : cabinet
    end
  end

  def timetable_rows
    records.select { |row| row['operation'] == 'timetable' && row['status_class'] == '2xx' }
           .flat_map { |row| row['body'].to_h.values.flat_map { |day| Array(day.to_h['timetable']) } }
  end

  def fields(title, rows)
    return "## #{title}\nНет строк для анализа." if rows.empty?

    keys = rows.flat_map { |row| row.is_a?(Hash) ? row.keys : [] }.uniq.sort
    (["## #{title}"] + keys.map { |key| field_line(rows, key) }).join("\n")
  end

  def field_line(rows, key)
    values = rows.select { |row| row.is_a?(Hash) && row.key?(key) }.pluck(key)
    types = values.map { |value| json_type(value) }.uniq.sort
    "- `#{key}`: #{types.join('/')} (есть #{values.size}/#{rows.size}, null #{values.count(&:nil?)})"
  end

  def json_type(value)
    case value
    when Hash then 'object'
    when Array then 'array'
    when String then 'string'
    when Numeric then 'number'
    when NilClass then 'null'
    else 'boolean'
    end
  end

  def day_section
    lines = [
      '## Дни и ответы',
      'Client возвращает объект с ключами дат dd.MM.yyyy; каждый ключ содержит объект дня.',
      'Пустой timetable подтверждает выходной только со строкой specialistWorkingHours="day off"; ' \
        'при объекте часов день остаётся непроверенным.'
    ]
    lines.concat(Integrations::Medelement::SampleCapture::OFFSETS.map { |offset| day_line(offset) })
    lines.join("\n")
  end

  def day_line(offset)
    rows = records.select { |row| row['operation'] == 'timetable' && row['offset'] == offset }
    states = rows.map { |row| "#{row['status_class']}/#{row['day_kind'] || 'ошибка'}" }
    "- #{(today + offset).iso8601} (#{offset >= 0 ? '+' : ''}#{offset}): " \
      "#{states.empty? ? 'не запрошен' : states.join(', ')}"
  end

  def doctor_section
    rows = records.select { |row| row['operation'] == 'timetable' }.group_by { |row| row['doctor'] }
    lines = rows.map { |digest, visits| doctor_line(digest, visits) }
    (['## Варианты врачей'] + lines).join("\n")
  end

  def doctor_line(digest, visits)
    states = visits.map { |visit| visit['day_kind'] || visit['status_class'] }.tally
    "- #{digest}: опубликован=#{visits.first['published']}, кабинетов=#{visits.first['cabinets']}, " \
      "дней=#{visits.size}, виды=#{states.map { |kind, count| "#{kind}: #{count}" }.join(', ')}"
  end

  def timing_section
    durations = records.pluck('duration_ms')
    average = durations.empty? ? 0 : (durations.sum.to_f / durations.size).round
    errors = records.count { |record| record['status_class'] != '2xx' }
    [
      '## Время и ошибки',
      "Время ответа: min=#{durations.min || 0} мс, max=#{durations.max || 0} мс; среднее=#{average} мс.",
      "Ошибок: #{errors}. Тела 4xx/5xx недоступны через Client; детали и сообщения исключений не сохраняются.",
      *error_lines
    ].join("\n")
  end

  def error_lines
    records.reject { |record| record['status_class'] == '2xx' }.map do |record|
      "- #{record['operation']} #{record['date'] || 'без даты'}: #{record['status_class']}; тело недоступно."
    end
  end
end
