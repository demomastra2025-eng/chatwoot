require 'csv'

class Campaigns::AudienceImportService
  MAX_FILE_SIZE = 5.megabytes
  MAX_ROWS = 10_000
  ERROR_SAMPLE_LIMIT = 50
  PHONE_HEADERS = %w[phone_number phone mobile telephone].freeze
  PHONE_CHANNEL_TYPES = %w[Channel::Sms Channel::TwilioSms Channel::Whatsapp Channel::WhatsappWeb].freeze
  DEFAULT_COUNTRY_PATTERN = /\A[A-Z]{2}\z/

  class Error < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super(code)
    end
  end

  def initialize(audience_import:)
    @audience_import = audience_import
    @account = audience_import.account
    @inbox = audience_import.inbox
    @default_country = audience_import.default_country
  end

  def perform
    validate_import!
    rows = with_import_file { |file| parsed_rows(file) }

    @audience_import.update!(status: :processing, total_rows: rows.size, processing_error: nil)
    CampaignAudienceImport.transaction do
      with_contact_identity_lock do
        @audience_import.recipients.delete_all
        process_rows(rows)
        persist_summary!
        @audience_import.update!(status: :completed)
      end
    end
    @audience_import
  rescue CSV::MalformedCSVError
    raise Error, 'malformed_csv'
  end

  private

  def validate_import!
    raise Error, 'file_required' unless @audience_import.import_file.attached?
    raise Error, 'invalid_default_country' unless @default_country.match?(DEFAULT_COUNTRY_PATTERN)
    raise Error, 'unsupported_inbox' unless @inbox.account_id == @account.id && PHONE_CHANNEL_TYPES.include?(@inbox.channel_type)
  end

  def parsed_rows(file)
    data = normalized_file_data(file)
    delimiter = csv_delimiter(data)
    csv = CSV.new(data, headers: true, col_sep: delimiter, skip_blanks: true)
    parsed_rows = []
    normalized_headers = nil

    csv.each do |row|
      normalized_headers ||= Array(row.headers).map { |header| normalize_header(header) }
      raise Error, 'too_many_rows' if parsed_rows.size >= MAX_ROWS

      parsed_rows << normalized_row(row)
    end
    normalized_headers ||= []
    raise Error, 'phone_column_required' unless normalized_headers.intersect?(PHONE_HEADERS)

    parsed_rows
  end

  def normalized_row(row)
    row.to_h.each_with_object({}) do |(key, value), normalized|
      normalized[normalize_header(key)] = value.to_s.strip
    end.with_indifferent_access
  end

  def normalized_file_data(file)
    file.rewind
    raw_data = file.read.to_s
    utf8_data = raw_data.force_encoding('UTF-8')
    raise Error, 'invalid_encoding' unless utf8_data.valid_encoding?

    utf8_data.delete_prefix("\xEF\xBB\xBF")
  end

  def csv_delimiter(data)
    first_line = data.each_line.first.to_s
    semicolon_headers = parsed_header_count(first_line, ';')
    comma_headers = parsed_header_count(first_line, ',')
    semicolon_headers > comma_headers ? ';' : ','
  end

  def parsed_header_count(line, delimiter)
    Array(CSV.parse_line(line, col_sep: delimiter)).map { |header| normalize_header(header) }.count(&:present?)
  rescue CSV::MalformedCSVError
    0
  end

  def normalize_header(header)
    header.to_s.delete_prefix("\uFEFF").strip.downcase.tr(' -', '__')
  end

  def with_import_file(&)
    @audience_import.import_file.open(&)
  end

  def process_rows(rows)
    @counts = Hash.new(0)
    @errors = []
    @seen_phone_numbers = Set.new

    rows.each_with_index do |row, index|
      process_row(row, index + 2)
    end
  end

  def process_row(row, source_row)
    phone_number = normalized_phone_number(row)
    return reject_row(source_row, 'missing_phone') if raw_phone_number(row).blank?
    return reject_row(source_row, 'invalid_phone') if phone_number.blank?
    return reject_row(source_row, 'duplicate_phone', counter: :duplicate_count) unless @seen_phone_numbers.add?(phone_number)

    ActiveRecord::Base.transaction(requires_new: true) do
      contact, created = resolve_contact(row, phone_number)
      create_recipient!(contact, phone_number, source_row, created)
    end
  rescue Error, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    reject_row(source_row, contact_error_code(e), counter: :conflict_count)
  end

  def resolve_contact(row, phone_number)
    matches = @account.contacts.where(phone_number: phone_number).limit(2).to_a
    raise Error, 'duplicate_existing_contacts' if matches.many?

    existing = matches.first
    raise Error, 'identity_conflict' if conflicting_identity?(row, existing)
    return [existing, false] if existing.present?

    contact = @account.contacts.create!(
      name: phone_number,
      phone_number: phone_number,
      email: row[:email].presence,
      identifier: row[:identifier].presence,
      additional_attributes: { country_code: @default_country }
    )
    [contact, true]
  end

  def conflicting_identity?(row, expected_contact)
    email_owner = @account.contacts.from_email(row[:email]) if row[:email].present?
    identifier_owner = @account.contacts.find_by(identifier: row[:identifier]) if row[:identifier].present?
    email_conflict = email_owner.present? && email_owner != expected_contact
    identifier_conflict = identifier_owner.present? && identifier_owner != expected_contact
    email_conflict || identifier_conflict
  end

  def create_recipient!(contact, phone_number, source_row, created)
    @audience_import.recipients.create!(
      account: @account,
      contact: contact,
      normalized_phone_number: phone_number,
      source_row: source_row,
      contact_created: created
    )
    @counts[created ? :created_count : :existing_count] += 1
    @counts[:recipient_count] += 1
  end

  def with_contact_identity_lock
    Contacts::PhoneIdentityLock.acquire!(account_id: @account.id)
    yield
  end

  def normalized_phone_number(row)
    Contacts::PhoneNumberNormalizer.normalize(raw_phone_number(row), default_country: @default_country)
  end

  def raw_phone_number(row)
    row_value(row, PHONE_HEADERS)
  end

  def row_value(row, headers)
    headers.filter_map { |header| row[header].presence }.first
  end

  def reject_row(source_row, code, counter: :invalid_count)
    @counts[counter] += 1
    @errors << { row: source_row, code: code } if @errors.size < ERROR_SAMPLE_LIMIT
    nil
  end

  def contact_error_code(error)
    return error.code if error.is_a?(Error)

    'contact_conflict'
  end

  def persist_summary!
    @audience_import.update!(
      recipient_count: @counts[:recipient_count],
      created_count: @counts[:created_count],
      existing_count: @counts[:existing_count],
      duplicate_count: @counts[:duplicate_count],
      invalid_count: @counts[:invalid_count],
      conflict_count: @counts[:conflict_count],
      error_samples: @errors
    )
  end
end
