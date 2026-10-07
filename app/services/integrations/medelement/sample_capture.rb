class Integrations::Medelement::SampleCapture
  OFFSETS = [-3, 0, 1, 3, 7, 14, 30, 60, 90].freeze
  MAX_DOCTORS = 3
  MAX_REQUESTS = 60
  STOP_AFTER_ERRORS = 3

  class Refused < StandardError; end

  def self.client_for(hook)
    configuration = Integrations::Medelement::Configuration.new(hook: hook)
    client = Integrations::Medelement::Client.new(configuration: configuration)
    request = client.instance_variable_get(:@request)
    request.instance_variable_set(
      :@retry_policy, Integrations::Medelement::SampleCaptureSingleAttemptPolicy.new(configuration: configuration)
    )
    client
  end

  def initialize(hook:, client: nil, **options)
    @hook = hook
    @client = client
    @today = options.fetch(:today, Date.current)
    @max_doctors = options.fetch(:max_doctors, MAX_DOCTORS).to_i.clamp(0, MAX_DOCTORS)
    @max_requests = options.fetch(:max_requests, MAX_REQUESTS).to_i.clamp(0, MAX_REQUESTS)
    @output_root = options.fetch(:output_root, Rails.root.join('tmp/medelement_samples'))
    @confirm = options.fetch(:confirm, ENV.fetch('CONFIRM', nil))
    @allow_production = options.fetch(:allow_production, ENV.fetch('ALLOW_PRODUCTION', nil))
    @production = options.fetch(:production, Rails.env.production?)
    @sanitizer = Integrations::Medelement::SampleSanitizer.new
    @records = []
  end

  def perform
    validate!
    specialists = capture('specialists') { client.specialists }
    doctors = select_doctors(Array(specialists))
    @selected_doctors = doctors.size
    doctors.each do |doctor|
      break if stopped?

      capture_doctor(doctor)
    end
    write_output(doctors)
  end

  def summary
    [
      "Запросов: #{records.size}/#{max_requests}",
      "Врачей выбрано: #{@selected_doctors || 0}",
      "Успешных 2xx: #{count_status('2xx')}",
      "Ошибок 4xx: #{count_status('4xx')}",
      "Ошибок 5xx: #{count_status('5xx')}",
      "Сетевых и прочих ошибок: #{count_status('network')}",
      "Дней расписания: #{records.count { |record| record['operation'] == 'timetable' }}",
      "Дней с рабочими интервалами: #{records.count { |record| record['day_kind'] == 'рабочий' }}",
      "Дней без рабочих интервалов: #{records.count { |record| record['day_kind'] == 'выходной или пустой' }}",
      "Остановлено после повторных ошибок: #{consecutive_errors >= STOP_AFTER_ERRORS ? 'да' : 'нет'}"
    ]
  end

  def select_doctors(rows)
    candidates = rows.select { |row| row.is_a?(Hash) && row['specialistCode'].present? }
    priorities = [
      candidates.find { |row| published?(row) },
      candidates.find { |row| !row['isSchedulePublished'].nil? && !published?(row) },
      candidates.find { |row| cabinet_count(row) > 1 }
    ]
    (priorities.compact + candidates).uniq.first(max_doctors)
  end

  private

  attr_reader :hook, :today, :max_doctors, :max_requests, :output_root, :sanitizer, :records

  def client
    @client ||= self.class.client_for(hook)
  end

  def validate!
    raise Refused, 'Production capture requires ALLOW_PRODUCTION=1' if @production && @allow_production != '1'
    raise Refused, 'The hook must belong to MedElement' unless hook.app_id == 'medelement'
    raise Refused, 'Enabled hook capture requires CONFIRM=1' if hook.enabled? && @confirm != '1'
    raise Refused, 'The request budget must allow the specialists request' if max_requests.zero?
  end

  def capture_doctor(doctor)
    code = doctor.fetch('specialistCode')
    OFFSETS.each do |offset|
      break if stopped?

      date = today + offset
      capture('timetable', date: date, offset: offset, doctor: doctor) do
        client.timetable(specialist_code: code, starts_on: date, ends_on: date)
      end
    end
  end

  def capture(operation, date: nil, offset: nil, doctor: nil)
    return if stopped?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    body = yield
    record = base_record(operation, started, date, offset, doctor)
    record['status_class'] = '2xx'
    record['body'] = sanitizer.sanitize(body)
    record['day_kind'] = day_kind(body) if operation == 'timetable'
    records << record
    @consecutive_errors = 0
    body
  rescue StandardError => e
    record = base_record(operation, started, date, offset, doctor)
    record['status_class'] = status_class(e)
    record['body'] = nil
    record['error'] = 'Ответ ошибки недоступен через Client'
    records << record
    @consecutive_errors = consecutive_errors + 1
    nil
  end

  def base_record(operation, started, date, offset, doctor)
    {
      'operation' => operation,
      'date' => date&.iso8601,
      'offset' => offset,
      'doctor' => doctor && sanitizer.digest(doctor['specialistCode']),
      'published' => doctor && published?(doctor),
      'cabinets' => doctor && cabinet_count(doctor),
      'duration_ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    }
  end

  def status_class(error)
    status = error.respond_to?(:status) ? error.status.to_i : 0
    return '4xx' if (400..499).cover?(status)
    return '5xx' if (500..599).cover?(status)

    'network'
  end

  def day_kind(body)
    rows = body.is_a?(Hash) ? body.values.flat_map { |day| Array(day.to_h['timetable']) } : []
    return 'выходной или пустой' if rows.empty?

    rows.any? { |row| Integrations::Medelement::WorkingFlag.working?(row.to_h['working']) } ? 'рабочий' : 'выходной или пустой'
  end

  def published?(doctor)
    Integrations::Medelement::WorkingFlag.working?(doctor['isSchedulePublished'])
  end

  def cabinet_count(doctor)
    Array(doctor['cabinets'].presence || doctor['cabinetCodes']).size
  end

  def stopped?
    records.size >= max_requests || consecutive_errors >= STOP_AFTER_ERRORS
  end

  def consecutive_errors
    @consecutive_errors ||= 0
  end

  def count_status(status)
    records.count { |record| record['status_class'] == status }
  end

  def write_output(doctors)
    FileUtils.mkdir_p(output_root, mode: 0o700)
    directory = output_root.join("#{Time.current.utc.strftime('%Y%m%dT%H%M%SZ')}-#{SecureRandom.hex(3)}")
    Dir.mkdir(directory, 0o700)
    File.open(directory.join('samples.json'), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(records))
    end
    File.open(directory.join('SHAPES.md'), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(Integrations::Medelement::SampleShapeReport.new(
        records: records, doctors: doctors, today: today
      ).render)
    end
    directory
  end
end
