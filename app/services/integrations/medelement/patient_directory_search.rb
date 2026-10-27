class Integrations::Medelement::PatientDirectorySearch
  LIMIT = 20
  TOKEN_PURPOSE = 'scheduling-medelement-patient-import'.freeze
  PHONE_CHARACTERS = /\A[\d+()\-\s]+\z/
  NAME_CHARACTERS = /\A\p{L}+(?: \p{L}+){0,2}\z/

  def initialize(account:, hook:, user:, client: nil, deadline: nil)
    @account = account
    @hook = hook
    @user = user
    @deadline = deadline || Integrations::Medelement::RequestDeadline.new
    @client = client || Integrations::Medelement::Client.new(
      configuration: Integrations::Medelement::Configuration.new(hook: hook), retry_profile: :lookup, deadline: @deadline
    )
  end

  def search(raw_query)
    kind, value = classify(raw_query)
    return empty_result(kind) unless %i[iin phone name].include?(kind)

    deadline.check!
    rows = Timeout.timeout(deadline.remaining) { search_rows(kind, value) }
    deadline.check!
    rows = eligible_rows(rows)
    { patients: serialized_rows(rows), truncated: rows.size > LIMIT }
  rescue Integrations::Medelement::Client::ApiError, Timeout::Error, Integrations::Medelement::ProviderScope::MismatchError
    raise Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_SEARCH_UNAVAILABLE', message: 'Patient search is temporarily unavailable',
                                status: :service_unavailable)
  end

  def import(token)
    code = verified_patient_code!(token)
    card = client.get_patient(patient_code: code)
    raise unavailable_error if card.blank?

    contact = sync_card(code, card)
    raise unavailable_error if contact.blank?

    contact
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    raise token_error
  rescue Integrations::Medelement::Client::ApiError, Timeout::Error, Integrations::Medelement::ProviderScope::MismatchError,
         ActiveRecord::RecordInvalid
    raise unavailable_error
  end

  private

  attr_reader :account, :hook, :user, :client, :deadline

  def empty_result(reason)
    { patients: [], reason: reason.to_s, truncated: false }
  end

  def eligible_rows(rows)
    Array(rows).select { |row| row.is_a?(Hash) && row['REMOVED'].to_s != '1' && patient_code(row).present? }
               .uniq { |row| patient_code(row) }
  end

  def serialized_rows(rows)
    codes = rows.first(LIMIT).map { |row| patient_code(row) }
    linked = account.contacts.where("custom_attributes ->> 'medelement_patient_code' IN (?)", codes)
                    .index_by { |contact| contact.custom_attributes['medelement_patient_code'].to_s }
    rows.first(LIMIT).map { |row| payload(row, linked[patient_code(row)]) }
  end

  def verified_patient_code!(token)
    identity = verifier.verified(token.to_s, purpose: TOKEN_PURPOSE)
    identity = identity.stringify_keys if identity.is_a?(Hash)
    valid = identity.is_a?(Hash) && identity['account_id'] == account.id && identity['hook_id'] == hook.id &&
            identity['user_id'] == user.id && identity['patient_code'].present?
    raise token_error unless valid

    identity.fetch('patient_code')
  end

  def sync_card(code, card)
    Integrations::Medelement::PatientsSyncService.new(
      account: account, client: client, organization_id: Integrations::Medelement::Configuration.new(hook: hook).organization_id
    ).sync_patient_codes([code], prefetched_patients: { code => card }, require_verified_card: true)[code]
  end

  def classify(raw)
    text = Search::QueryText.clean(raw)
    return classify_numeric(text) if text.match?(PHONE_CHARACTERS)

    classify_name(text)
  end

  def classify_numeric(text)
    digits = text.gsub(/[\s-]/, '')
    if text.match?(/\A[\d\s-]+\z/) && digits.match?(/\A\d{12}\z/)
      return [:invalid_iin, nil] unless Scheduling::IinValidator.valid?(digits)

      return [:iin, digits]
    end
    phone = Integrations::Medelement::PhoneNumber.normalize(text)
    return [:phone, phone] if phone.present?

    [:too_short, nil]
  end

  def classify_name(text)
    return [:unsupported, nil] unless text.match?(NAME_CHARACTERS)

    words = text.split
    return [:too_short, nil] unless words.all? { |word| word.length >= 2 } && words.any? { |word| word.length >= 3 }

    [:name, words]
  end

  def search_rows(kind, value)
    case kind
    when :iin then client.search_patients_by_iin(iin: value)
    when :phone then client.search_patients_by_phone(phone_number: value)
    else
      first = client.search_patients_by_name(lastname: value[0], name: value[1], middlename: value[2])
      return first if first.present?

      client.search_patients_by_name(name: value[0], middlename: (value[1] if value.length == 3),
                                     lastname: value.length == 1 ? nil : value.last)
    end
  end

  def payload(row, contact)
    { token: token_for(row), full_name: [row['LASTNAME'], row['NAME'], row['MIDDLENAME']].filter_map(&:presence).join(' '),
      **identity_fields(row), linked_contact_id: contact&.id }
  end

  def token_for(row)
    verifier.generate(
      { account_id: account.id, hook_id: hook.id, user_id: user.id, patient_code: patient_code(row) },
      expires_in: 15.minutes, purpose: TOKEN_PURPOSE
    )
  end

  def identity_fields(row)
    iin = row['IIN'].to_s.gsub(/\D/, '')
    {
      first_name: row['NAME'].presence, last_name: row['LASTNAME'].presence, middle_name: row['MIDDLENAME'].presence,
      birth_date: birth_date(row['BIRTHDAY']), iin_masked: ("••••#{iin.last(4)}" if iin.present?),
      phone_known: row.values_at('PATIENT_PHONE_2', 'PHONES_STR').any?(&:present?)
    }
  end

  def birth_date(value)
    return if value.blank?

    date = value.to_s.match?(/\A\d{2}\.\d{2}\.\d{4}\z/) ? Date.strptime(value.to_s, '%d.%m.%Y') : Date.iso8601(value.to_s)
    date.iso8601
  rescue Date::Error
    nil
  end

  def patient_code(row)
    Integrations::Medelement::ProviderCommands::PatientResolver.patient_code(row)
  end

  def verifier
    Rails.application.message_verifier(TOKEN_PURPOSE)
  end

  def token_error
    Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_TOKEN_INVALID', message: 'Search for the patient again', status: :unprocessable_content)
  end

  def unavailable_error
    Scheduling::Error.new(code: 'MEDELEMENT_PATIENT_UNAVAILABLE', message: 'Patient is temporarily unavailable', status: :unprocessable_content)
  end
end
