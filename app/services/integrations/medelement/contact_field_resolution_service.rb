# rubocop:disable Metrics/ClassLength
class Integrations::Medelement::ContactFieldResolutionService
  class ResolutionError < StandardError; end

  class FieldAlreadyUsedError < ResolutionError
    attr_reader :field, :contact_id, :value

    def initialize(field:, contact_id:, value: nil)
      @field = field
      @contact_id = contact_id
      @value = value
      super("#{field} is already used by contact ##{contact_id}")
    end
  end

  FIELDS = %w[first_name last_name middle_name phone iin birth_date gender email address].freeze
  OUTBOUND_FIELDS = (FIELDS - ['address']).freeze
  DIRECTIONS = %w[medelement_to_onelink onelink_to_medelement].freeze
  UNIQUE_CONTACT_FIELDS = { 'phone' => 'phone_number', 'iin' => 'identifier', 'email' => 'email' }.freeze
  UNIQUE_CONSTRAINT_FIELDS = {
    'uniq_email_per_account_contact' => 'email',
    'uniq_identifier_per_account_contact' => 'iin'
  }.freeze
  PROVIDER_COMMAND_METADATA_KEY = 'contact_field_resolution'.freeze

  def self.apply_provider_command!(command)
    metadata = command.execution_state.to_h.fetch(PROVIDER_COMMAND_METADATA_KEY)
    conflict = Integrations::Medelement::SyncConflict.find_by!(
      id: metadata.fetch('conflict_id'),
      account_id: command.account_id,
      hook_id: command.hook_id
    )
    user = command.account.users.find(metadata.fetch('user_id'))
    service = new(conflict: conflict, user: user)
    service.send(:apply_provider_command_result!, command, metadata)
  end

  def self.record_provider_command_conflict!(command, error)
    metadata = command.execution_state.to_h.fetch(PROVIDER_COMMAND_METADATA_KEY)
    conflict = Integrations::Medelement::SyncConflict.find_by!(
      id: metadata.fetch('conflict_id'), account_id: command.account_id, hook_id: command.hook_id
    )
    user = command.account.users.find(metadata.fetch('user_id'))
    new(conflict: conflict, user: user).send(:record_conflicting_contact!, error)
  end

  def initialize(conflict:, user:, client: nil)
    @conflict = conflict
    @user = user
    @client = client
  end

  def perform(field_directions:)
    directions = normalize_directions(field_directions)
    validate_request!(directions)
    outbound_fields = fields_for(directions, 'onelink_to_medelement')

    return perform_local_resolution!(directions) if outbound_fields.empty?

    perform_provider_resolution!(directions)
  rescue FieldAlreadyUsedError => e
    record_conflicting_contact!(e)
    raise
  end

  private

  attr_reader :conflict, :user, :client

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def perform_local_resolution!(directions)
    conflict.with_lock do
      raise ResolutionError, 'Only open conflicts can be resolved' unless conflict.open?

      contact = conflict.account.contacts.find(conflict.details.fetch('contact_id'))
      patient_code = contact.custom_attributes['medelement_patient_code'].to_s
      raise ResolutionError, 'MedElement patient reference is missing' if patient_code.blank?

      patient = medelement_client.get_patient(patient_code: patient_code)
      provider = provider_values(patient)
      local = onelink_values(contact)
      inbound_fields = fields_for(directions, 'medelement_to_onelink')
      outbound_fields = fields_for(directions, 'onelink_to_medelement')
      ensure_selected_values!(provider, inbound_fields, 'MedElement')
      ensure_selected_values!(local, outbound_fields, 'OneLink')
      ensure_unique_inbound_fields!(contact, provider, inbound_fields)

      desired_provider = provider.merge(local.slice(*outbound_fields))
      apply_provider_fields!(contact, provider, inbound_fields, desired_provider) if inbound_fields.present?
      apply_onelink_fields!(contact, patient_code, outbound_fields, provider, local)

      conflict.update!(
        status: 'resolved',
        resolved_by: user,
        resolved_at: Time.current,
        resolution_note: "Fields synchronized: #{directions.map { |field, direction| "#{field}=#{direction}" }.join(', ')}"
      )
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def perform_provider_resolution!(directions)
    command = existing_resolution_command(directions) || create_resolution_command!(directions)
    drive_resolution_command!(command)
    command.reload
    finalize_provider_resolution!(command)
  end

  def finalize_provider_resolution!(command)
    self.class.apply_provider_command!(command) if command.succeeded? && conflict.reload.open?
    return if command.succeeded? && conflict.reload.resolved?

    raise_recorded_field_conflict!(command) if command.last_error_code == 'contact_field_conflict'

    handle_pending_provider_resolution!(command)
  end

  def handle_pending_provider_resolution!(command)
    schedule_reconciliation(command) if command.reconciliation_required?
    raise ResolutionError, "MedElement field synchronization is pending: #{command.last_error_code || command.logical_status}"
  end

  def existing_resolution_command(directions)
    Integrations::Medelement::ProviderCommand.find_by(
      account: conflict.account,
      idempotency_key: resolution_idempotency_key(directions)
    )
  end

  def create_resolution_command!(directions)
    context = prepare_provider_resolution(directions)
    command = Integrations::Medelement::ProviderCommands::CreateService.new(
      account: conflict.account,
      hook: conflict.hook,
      contact: context.fetch(:contact),
      operation: 'update_patient',
      idempotency_key: resolution_idempotency_key(directions),
      actor: user,
      desired_attributes: provider_command_attributes(context.fetch(:contact), context.fetch(:desired_provider))
    ).perform
    persist_resolution_metadata!(command, directions, context)
    command
  end

  # rubocop:disable Metrics/AbcSize
  def prepare_provider_resolution(directions)
    conflict.with_lock do
      raise ResolutionError, 'Only open conflicts can be resolved' unless conflict.open?

      contact = conflict.account.contacts.find(conflict.details.fetch('contact_id'))
      patient_code = contact.custom_attributes['medelement_patient_code'].to_s
      raise ResolutionError, 'MedElement patient reference is missing' if patient_code.blank?

      provider = provider_values(medelement_client.get_patient(patient_code: patient_code))
      local = onelink_values(contact)
      inbound_fields = fields_for(directions, 'medelement_to_onelink')
      outbound_fields = fields_for(directions, 'onelink_to_medelement')
      ensure_selected_values!(provider, inbound_fields, 'MedElement')
      ensure_selected_values!(local, outbound_fields, 'OneLink')
      ensure_unique_inbound_fields!(contact, provider, inbound_fields)
      {
        contact: contact,
        provider: provider,
        desired_provider: provider.merge(local.slice(*outbound_fields))
      }
    end
  end
  # rubocop:enable Metrics/AbcSize

  def provider_command_attributes(contact, desired)
    {
      'name' => desired['first_name'],
      'last_name' => desired['last_name'],
      'middle_name' => desired['middle_name'],
      'phone_number' => desired['phone'],
      'email' => desired['email'],
      'gender' => desired['gender'],
      'custom_attributes' => contact.custom_attributes.to_h.merge(
        'medelement_first_name' => desired['first_name'],
        'medelement_last_name' => desired['last_name'],
        'medelement_middle_name' => desired['middle_name'],
        'medelement_iin' => desired['iin'],
        'medelement_birth_date' => desired['birth_date'],
        'medelement_gender' => desired['gender']
      )
    }
  end

  def persist_resolution_metadata!(command, directions, context)
    metadata = {
      'version' => 1,
      'conflict_id' => conflict.id,
      'contact_id' => context.fetch(:contact).id,
      'user_id' => user.id,
      'directions' => directions,
      'provider' => context.fetch(:provider),
      'desired_provider' => context.fetch(:desired_provider)
    }
    metadata['fingerprint'] = resolution_metadata_fingerprint(metadata)
    command.with_lock do
      existing = command.execution_state.to_h[PROVIDER_COMMAND_METADATA_KEY]
      raise ResolutionError, 'MedElement field synchronization intent changed' if existing.present? && existing != metadata

      command.update!(execution_state: command.execution_state.merge(PROVIDER_COMMAND_METADATA_KEY => metadata)) if existing.blank?
    end
  end

  def drive_resolution_command!(command)
    if command.awaiting_confirmation?
      Integrations::Medelement::ProviderCommands::AutoConfirmationService.new(command: command).perform
      Integrations::Medelement::ProviderCommandConfirmationJob.perform_now(command.confirmation_request_id)
      command.reload
    end
    if command.queued?
      Integrations::Medelement::ProviderCommands::Executor.new(command: command, client: client).perform
    elsif command.reconciliation_required? && client.present?
      Integrations::Medelement::ProviderCommands::ReconciliationService.new(command: command, client: client).perform
    end
  end

  def schedule_reconciliation(command)
    Integrations::Medelement::ProviderCommandReconciliationJob.perform_later(command.id)
  end

  def raise_recorded_field_conflict!(command)
    details = conflict.reload.details.to_h
    field = details['conflicting_field'].to_s
    contact_id = Integer(details['conflicting_contact_id'], exception: false)
    raise ResolutionError, 'MedElement field synchronization has an unresolved contact collision' if field.blank? || contact_id.blank?

    provider = command.execution_state.to_h.dig(PROVIDER_COMMAND_METADATA_KEY, 'provider').to_h
    raise FieldAlreadyUsedError.new(field: field, contact_id: contact_id, value: provider[field])
  end

  def resolution_idempotency_key(directions)
    fingerprint = Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(directions.sort.to_h)
    "contact-field-resolution:#{conflict.id}:#{fingerprint}"
  end

  def resolution_metadata_fingerprint(metadata)
    Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(metadata.except('fingerprint'))
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def apply_provider_command_result!(command, metadata)
    validate_resolution_metadata!(command, metadata)
    conflict.with_lock do
      next true if conflict.resolved?

      raise ResolutionError, 'Only open conflicts can be resolved' unless conflict.open?

      contact = conflict.account.contacts.find(metadata.fetch('contact_id'))
      provider = metadata.fetch('provider')
      desired_provider = metadata.fetch('desired_provider')
      directions = metadata.fetch('directions')
      inbound_fields = fields_for(directions, 'medelement_to_onelink')
      ensure_unique_inbound_fields!(contact, provider, inbound_fields)
      apply_provider_fields!(contact, provider, inbound_fields, desired_provider) if inbound_fields.present?
      persist_resolved_provider_snapshot!(contact, desired_provider, directions)
      conflict.update!(
        status: 'resolved',
        resolved_by: user,
        resolved_at: Time.current,
        details: conflict.details.merge('resolution_provider_command_id' => command.id),
        resolution_note: "Fields synchronized: #{directions.map { |field, direction| "#{field}=#{direction}" }.join(', ')}"
      )
      true
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  def validate_resolution_metadata!(command, metadata)
    expected = resolution_metadata_fingerprint(metadata)
    raise ResolutionError, 'MedElement field synchronization metadata is invalid' unless metadata['fingerprint'] == expected
    return if command.update_patient? && command.contact_id == metadata['contact_id'] && command.hook_id == conflict.hook_id

    raise ResolutionError, 'MedElement field synchronization target changed'
  end

  def persist_resolved_provider_snapshot!(contact, desired_provider, directions)
    custom = contact.reload.custom_attributes.to_h
    apply_provider_snapshot!(custom, desired_provider)
    custom.delete('phone_conflict_comment') if directions.key?('phone')
    return if custom == contact.custom_attributes.to_h

    contact.skip_runtime_events = true
    contact.update!(custom_attributes: custom)
  end

  def normalize_directions(field_directions)
    values = if field_directions.respond_to?(:to_unsafe_h)
               field_directions.to_unsafe_h
             elsif field_directions.respond_to?(:to_h)
               field_directions.to_h
             else
               raise ArgumentError, 'Field directions must be an object'
             end
    values.stringify_keys.transform_values(&:to_s)
  end

  def validate_request!(directions)
    raise ResolutionError, 'Field synchronization is only available for phone mismatches' unless conflict.conflict_type == 'phone_mismatch'
    raise ArgumentError, 'Select at least one supported field direction' if directions.empty? || (directions.keys - FIELDS).any?
    raise ArgumentError, 'Unsupported synchronization direction' if (directions.values - DIRECTIONS).any?

    validate_outbound_request!(directions)
  end

  def validate_outbound_request!(directions)
    outbound_fields = fields_for(directions, 'onelink_to_medelement')

    raise ArgumentError, 'Selected field cannot be written to MedElement' if outbound_fields.intersect?(FIELDS - OUTBOUND_FIELDS)

    return if outbound_fields.empty?
    return if conflict.hook.enabled? && conflict.hook.feature_allowed? && configuration.write_enabled?

    raise ResolutionError, 'MedElement writes are disabled for this integration'
  end

  def fields_for(directions, direction)
    directions.select { |_field, selected_direction| selected_direction == direction }.keys
  end

  def medelement_client
    @medelement_client ||= client || Integrations::Medelement::Client.new(configuration: configuration)
  end

  def configuration
    @configuration ||= Integrations::Medelement::Configuration.new(hook: conflict.hook)
  end

  # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def apply_provider_fields!(contact, provider, fields, provider_snapshot)
    attributes = {}
    custom = contact.custom_attributes.to_h
    attributes['name'] = provider['first_name'] if fields.include?('first_name')
    attributes['last_name'] = provider['last_name'] if fields.include?('last_name')
    attributes['middle_name'] = provider['middle_name'] if fields.include?('middle_name')
    attributes['phone_number'] = provider['phone'] if fields.include?('phone')
    attributes['identifier'] = provider['iin'] if fields.include?('iin')
    attributes['email'] = provider['email'] if fields.include?('email')
    %w[birth_date gender address].each { |field| custom[field] = provider[field] if fields.include?(field) }
    apply_provider_snapshot!(custom, provider_snapshot)
    if fields.include?('phone')
      custom['secondary_phones'] = merged_secondary_phones(contact, provider['phone'])
      custom.delete('phone_conflict_comment')
    end

    contact.skip_runtime_events = true
    persist_provider_fields!(contact, attributes.merge('custom_attributes' => custom))
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    collision = normalized_unique_write_error(e, contact, provider, fields)
    raise unless collision

    raise collision
  end

  # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
  def apply_onelink_fields!(contact, patient_code, fields, provider, local)
    return provider if fields.empty?

    desired = provider.merge(local.slice(*fields))
    payload = patient_payload(contact, patient_code, desired)

    Integrations::Medelement::ProviderScope.validate_write!(payload, organization_id: configuration.organization_id)
    medelement_client.update_patient(params: payload)

    custom = contact.custom_attributes.to_h
    apply_provider_snapshot!(custom, desired)
    custom.delete('phone_conflict_comment') if fields.include?('phone')
    contact.skip_runtime_events = true
    contact.update!(custom_attributes: custom)
    desired
  end

  # rubocop:disable Metrics/MethodLength
  def patient_payload(contact, patient_code, values)
    Integrations::Medelement::ProviderCommands::PatientPayloadBuilder.new(
      contact: contact,
      patient_code: patient_code,
      phone_number: values['phone'],
      organization_id: configuration.organization_id,
      desired_attributes: {
        'name' => values['first_name'],
        'last_name' => values['last_name'],
        'middle_name' => values['middle_name'],
        'email' => values['email'],
        'gender' => values['gender'],
        'custom_attributes' => {
          'medelement_first_name' => values['first_name'],
          'medelement_last_name' => values['last_name'],
          'medelement_middle_name' => values['middle_name'],
          'medelement_iin' => values['iin'],
          'medelement_birth_date' => values['birth_date'],
          'medelement_gender' => values['gender']
        }
      }
    ).build
  end

  # rubocop:enable Metrics/MethodLength
  def provider_values(patient)
    {
      'first_name' => patient['NAME'].to_s.presence,
      'last_name' => patient['LASTNAME'].to_s.presence,
      'middle_name' => patient['MIDDLENAME'].to_s.presence,
      'phone' => Integrations::Medelement::PhoneNumber.patient_phones(patient).first,
      'iin' => normalized_iin(patient['IIN']),
      'birth_date' => normalized_date(patient['BIRTHDAY']),
      'gender' => provider_gender(patient['GENDER']),
      'email' => patient['PATIENT_EMAIL'].to_s.downcase.presence,
      'address' => patient['FULL_ADDRESS'].to_s.presence
    }
  end

  # rubocop:disable Metrics/AbcSize
  def onelink_values(contact)
    custom = contact.custom_attributes.to_h
    {
      'first_name' => contact.name.to_s.presence,
      'last_name' => contact.last_name.to_s.presence,
      'middle_name' => contact.middle_name.to_s.presence,
      'phone' => Integrations::Medelement::PhoneNumber.normalize(contact.phone_number),
      'iin' => normalized_iin(contact.identifier.presence || custom['iin']),
      'birth_date' => normalized_date(custom['birth_date']),
      'gender' => custom['gender'].to_s.presence,
      'email' => contact.email.to_s.downcase.presence,
      'address' => custom['address'].to_s.presence
    }
  end

  # rubocop:enable Metrics/AbcSize
  def apply_provider_snapshot!(custom, values)
    custom.merge!(
      'medelement_first_name' => values['first_name'],
      'medelement_last_name' => values['last_name'],
      'medelement_middle_name' => values['middle_name'],
      'medelement_iin' => values['iin'],
      'medelement_birth_date' => values['birth_date'],
      'medelement_gender' => values['gender'],
      'medelement_email' => values['email'],
      'medelement_address' => values['address']
    )
  end

  def merged_secondary_phones(contact, provider_phone)
    current = Integrations::Medelement::PhoneNumber.normalize(contact.phone_number)
    (Array(contact.custom_attributes['secondary_phones']) + [current]).compact_blank.filter_map do |phone|
      Integrations::Medelement::PhoneNumber.normalize(phone)
    end.uniq - [provider_phone]
  end

  def ensure_selected_values!(values, fields, source)
    missing = fields.select { |field| values[field].blank? }
    raise ResolutionError, "#{source} has no value for: #{missing.join(', ')}" if missing.present?
  end

  def ensure_unique_inbound_fields!(contact, provider, fields)
    error = unique_inbound_collision(contact, provider, fields)
    raise error if error
  end

  def unique_inbound_collision(contact, provider, fields)
    return if contact.blank? || provider.blank? || fields.blank?

    UNIQUE_CONTACT_FIELDS.slice(*fields).each do |field, attribute|
      scope = contact.account.contacts.where.not(id: contact.id)
      duplicate = if attribute == 'email'
                    scope.where('LOWER(email) = ?', provider[field].downcase).first
                  else
                    scope.find_by(attribute => provider[field])
                  end
      return FieldAlreadyUsedError.new(field: field, contact_id: duplicate.id, value: provider[field]) if duplicate
    end
    nil
  end

  def normalized_unique_write_error(error, contact, provider, fields)
    field = unique_error_field(error, fields)
    return if field.blank?

    unique_inbound_collision(contact, provider, [field])
  end

  def unique_error_field(error, fields)
    return unique_validation_error_field(error, fields) if error.is_a?(ActiveRecord::RecordInvalid)

    UNIQUE_CONSTRAINT_FIELDS.find { |constraint, _field| error.message.include?(constraint) }&.last
  end

  def unique_validation_error_field(error, fields)
    selected_attributes = fields.filter_map do |field|
      attribute = UNIQUE_CONTACT_FIELDS[field]
      [field, attribute] if attribute
    end
    selected_attributes.find do |_field, attribute|
      error.record.errors.details[attribute.to_sym].any? { |detail| detail[:error] == :taken }
    end&.first
  end

  def persist_provider_fields!(contact, attributes)
    contact.update!(attributes)
  end

  def record_conflicting_contact!(error)
    attribute = UNIQUE_CONTACT_FIELDS[error.field]
    return if attribute.blank? || error.value.blank?

    conflict.with_lock do
      next unless conflict.open?

      contact = conflict.account.contacts.find_by(id: error.contact_id)
      next unless contact && unique_value_matches?(contact.public_send(attribute), error.value, attribute)

      conflict.update!(details: conflict.details.merge(
        'conflicting_contact_id' => contact.id,
        'conflicting_field' => error.field
      ))
    end
  end

  def unique_value_matches?(actual, expected, attribute)
    return actual.to_s.casecmp?(expected.to_s) if attribute == 'email'

    actual.to_s == expected.to_s
  end

  def normalized_iin(value)
    value.to_s.gsub(/\D/, '').presence
  end

  def normalized_date(value)
    return if value.blank?

    Date.parse(value.to_s).iso8601
  rescue Date::Error
    nil
  end

  def provider_gender(value)
    { '1' => 'female', '2' => 'male', 'female' => 'female', 'male' => 'male' }[value.to_s.downcase]
  end
end
# rubocop:enable Metrics/ClassLength
