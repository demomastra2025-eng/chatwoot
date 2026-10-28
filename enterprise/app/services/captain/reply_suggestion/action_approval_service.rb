# frozen_string_literal: true

require 'digest'
require 'json'
require 'securerandom'

class Captain::ReplySuggestion::ActionApprovalService
  TTL = 30.minutes.to_i
  LOCK_TTL = 30
  REDIS_KEY_PREFIX = 'captain:reply_suggestion:action_approval'
  CONVERSATION_INDEX_PREFIX = 'captain:reply_suggestion:conversation_actions'
  LOCK_PREFIX = 'captain:reply_suggestion:action_lock'
  CONTEXT_KEY = :captain_suggestion_pending_actions
  INDEX_LIMIT = 25

  PENDING_STATUS = 'pending'
  EXECUTING_STATUS = 'executing'
  APPROVED_STATUS = 'approved'
  REJECTED_STATUS = 'rejected'
  FAILED_STATUS = 'failed'

  APPOINTMENT_TOOLS = %w[create_appointment update_appointment cancel_appointment].freeze

  ACTION_TITLES = {
    'create_appointment' => 'Записать на приём',
    'update_appointment' => 'Перенести или изменить запись на приём',
    'cancel_appointment' => 'Отменить запись на приём',
    'create_deal' => 'Создать сделку',
    'update_deal' => 'Обновить сделку',
    'transition_deal_stage' => 'Сменить этап сделки',
    'create_task' => 'Создать задачу',
    'update_task' => 'Обновить задачу',
    'change_task_status' => 'Изменить статус задачи',
    'update_contact' => 'Обновить карточку контакта',
    'update_my_contact' => 'Обновить карточку контакта',
    'create_company' => 'Создать компанию',
    'update_company' => 'Обновить компанию',
    'add_private_note' => 'Добавить приватную заметку',
    'add_contact_note' => 'Добавить заметку к контакту',
    'add_label_to_conversation' => 'Добавить метку к диалогу',
    'update_priority' => 'Изменить приоритет диалога'
  }.freeze
  # What a card is, in the result the agent reads: an appointment card names its kind, every other card says it is no appointment.
  # A contact update read as a booking made a draft report a booking that had no card.
  APPROVAL_SCOPES = {
    'create_appointment' => 'a new appointment booking',
    'update_appointment' => 'a change of an existing appointment',
    'cancel_appointment' => 'a cancellation of an existing appointment'
  }.freeze
  NOT_APPOINTMENT_SCOPE = 'not an appointment: it books, moves or cancels nothing'
  # The cards that a corrected card replaced (see supersede_in_run! and supersede_kept!): the suggestion and the panel leave them out.
  SUPERSEDED_CONTEXT_KEY = :captain_suggestion_superseded_actions
  SUPERSEDED_REASON = 'superseded_in_run'
  # A kept card of an earlier suggestion that a corrected booking replaced (see supersede_kept!).
  KEPT_SUPERSEDED_REASON = 'superseded_by_later_booking'
  SUPERSEDED_REASONS = [SUPERSEDED_REASON, KEPT_SUPERSEDED_REASON].freeze
  # The letters a patient's name is compared by (see name_letters).
  NAME_LETTER_FOLDS = {
    'ё' => 'е', 'ә' => 'а', 'ғ' => 'г', 'қ' => 'к', 'ң' => 'н', 'ө' => 'о', 'ұ' => 'у', 'ү' => 'у', 'һ' => 'х', 'і' => 'и', 'ь' => '', 'ъ' => ''
  }.freeze
  NAME_LETTER_PATTERN = Regexp.union(NAME_LETTER_FOLDS.keys)

  class Error < StandardError; end
  class NotFoundError < Error; end
  class ForbiddenError < Error; end
  class InvalidStateError < Error; end

  class ExecutionError < Error
    attr_reader :action

    def initialize(message, action: nil)
      @action = action
      super(message)
    end
  end

  class << self
    # replaces: the ids of this run's cards that the new card replaces (another change or cancellation of the same appointment). A
    # booking finds the cards it replaces itself (see replaced_booking_ids and supersede_kept!). They are withdrawn only once the new
    # card exists; a refused call leaves them as they are.
    def intercept(tool:, tool_context:, arguments:, replaces: [])
      new_interception(tool: tool, tool_context: tool_context, arguments: arguments, replaces: replaces)
    end

    def appointment_tool?(tool_name)
      canonical_tool_name(tool_name).in?(APPOINTMENT_TOOLS)
    end

    # The pending cards of the conversation. request_id: only the cards of that suggestion request, and after them the kept cards (of
    # a suggestion the manager inserted or sent, see keep_for_request!); the same action is shown once.
    def pending_for(account_id:, conversation_id:, request_id: nil)
      records = pending_records(account_id, conversation_id)
      records = own_then_kept(records, request_id) if request_id
      records.map { |record| public_payload(record) }.uniq { |item| item['digest'] || item['action_id'] }
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ActionApprovalService] pending_for failed: #{e.class}: #{e.message}")
      []
    end

    def own_then_kept(records, request_id)
      own, others = records.partition { |record| record['suggestion_request_id'].to_s == request_id.to_s }
      own + others.select { |record| kept?(record) }
    end

    # A new suggestion of this manager starts in the conversation: the pending cards of the manager's earlier suggestions there (and
    # cards that name no manager or request) are discarded, so that the new suggestion does not show them again next to its own.
    # Cards of other managers' suggestions stay, and so do the kept cards: the manager inserted or sent their text (the patient may
    # already have read «Записала вас на 14:00») and the action still waits for «Разрешить».
    def discard_superseded!(account_id:, conversation_id:, user_id:, keep_request_id:)
      superseded = pending_records(account_id, conversation_id).select do |record|
        (record['user_id'].blank? || record['user_id'].to_i == user_id.to_i) &&
          record['suggestion_request_id'].to_s != keep_request_id.to_s && !kept?(record)
      end
      discard!(action_ids: superseded.pluck('action_id'), reason: 'suggestion_superseded')
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ActionApprovalService] discard_superseded failed: #{e.class}: #{e.message}")
    end

    # The manager inserted or sent the draft of this request: its pending cards are kept until the manager approves or rejects them
    # (or they expire), and the next suggestions show them again.
    def keep_for_request!(account_id:, conversation_id:, request_id:)
      cards = pending_records(account_id, conversation_id).select { |record| record['suggestion_request_id'].to_s == request_id.to_s }
      cards.reject { |record| kept?(record) }.each { |record| update_record!(record.merge('kept_at' => Time.current.iso8601)) }
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ActionApprovalService] keep_for_request failed: #{e.class}: #{e.message}")
    end

    def kept?(record)
      record['kept_at'].present?
    end

    # The manager dismissed the suggestion: its pending cards go with it.
    def discard_for_request!(account_id:, conversation_id:, request_id:, reason:)
      cards = pending_records(account_id, conversation_id).select { |record| record['suggestion_request_id'].to_s == request_id.to_s }
      discard!(action_ids: cards.pluck('action_id'), reason: reason)
    rescue StandardError => e
      Rails.logger.warn("[CAPTAIN][ActionApprovalService] discard_for_request failed: #{e.class}: #{e.message}")
    end

    def pending_records(account_id, conversation_id)
      return [] if account_id.blank? || conversation_id.blank?

      raw_ids = Redis::Alfred.get(conversation_index_key(account_id, conversation_id))
      ids = raw_ids.present? ? Array(JSON.parse(raw_ids)) : []
      ids.filter_map { |action_id| fetch_record(action_id) }.select { |record| pending_in?(record, account_id, conversation_id) }
    end

    def pending_in?(record, account_id, conversation_id)
      record['status'] == PENDING_STATUS && record['account_id'].to_i == account_id.to_i &&
        record['conversation_id'].to_i == conversation_id.to_i
    end

    def fetch_record(action_id)
      return if action_id.blank?

      raw = Redis::Alfred.get(redis_key(action_id))
      return if raw.blank?

      parsed = JSON.parse(raw)
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end

    # Stores a card of the current run (a pending one is registered with the run, see track_for_run).
    def store_record!(record)
      return unless write_record!(record)

      track_for_run(record)
      record
    end

    # Stores a card that is not the current run's own (a kept or a discarded card): a run that does not finish discards only the cards
    # it prepared.
    def update_record!(record)
      record if write_record!(record)
    end

    # The conversation index is updated in one atomic step (parts of a council store their cards from threads of their own).
    def write_record!(record)
      action_id = record['action_id'].to_s
      return false if action_id.blank?

      Redis::Alfred.set(redis_key(action_id), JSON.generate(record), ex: TTL)
      if record['account_id'].present? && record['conversation_id'].present?
        Redis::Alfred.prepend_to_json_list(conversation_index_key(record['account_id'], record['conversation_id']), action_id,
                                           limit: INDEX_LIMIT, ex: TTL)
      end
      true
    end

    # Rejects the cards of a suggestion run that did not finish (failed, cancelled): it leaves no partial result behind, the cards
    # included. Cards that were already acted on stay as they are.
    def discard!(action_ids:, reason:)
      Array(action_ids).each do |action_id|
        record = fetch_record(action_id)
        next unless record && record['status'] == PENDING_STATUS

        update_record!(record.merge('status' => REJECTED_STATUS, 'rejected_at' => Time.current.iso8601, 'rejected_reason' => reason.to_s))
        restore_replaced_kept!(record)
      end
    end

    # The kept cards that a booking card replaced come back when that card goes before its draft reached the patient (its suggestion
    # did not finish, was dismissed or gave way to a new one, a corrected card of its run replaced it, or the operator denied it, see
    # reject!): the draft the patient read still stands. A kept card that changed since (the operator acted on it, another card
    # replaced it) stays as it is.
    def restore_replaced_kept!(record)
      Array(record['replaced_kept_ids']).each do |kept_id|
        kept = fetch_record(kept_id)
        next unless kept && kept['status'] == REJECTED_STATUS && kept['superseded_by'].to_s == record['action_id'].to_s

        update_record!(kept.except('rejected_at', 'rejected_reason', 'superseded_by').merge('status' => PENDING_STATUS))
      end
    end

    # A card that a corrected card replaced: a card of the same run, or a kept card of an earlier suggestion.
    def superseded?(record)
      record['status'] == REJECTED_STATUS && SUPERSEDED_REASONS.include?(record['rejected_reason'].to_s)
    end

    # The run that prepares a card knows it (RunControl), so that it can discard the card if the run does not finish.
    def track_for_run(record)
      Captain::ReplySuggestion::RunControl.register_action(record['action_id']) if record['status'] == PENDING_STATUS
    end

    def public_payload(record)
      return {} unless record.is_a?(Hash)

      {
        'action_id' => record['action_id'],
        'tool_name' => record['tool_name'],
        'status' => record['status'],
        'title' => record['title'],
        'description' => record['description'],
        'details' => Array(record['details']),
        'agent' => record['agent'],
        'digest' => record['digest'],
        'conversation_id' => record['conversation_id'],
        'conversation_display_id' => record['conversation_display_id'],
        'created_at' => record['created_at'],
        'approved_at' => record['approved_at'],
        'rejected_at' => record['rejected_at'],
        'failed_at' => record['failed_at'],
        'error_message' => record['error_message'],
        'result_summary' => record['result_summary']
      }.compact
    end

    def canonical_tool_name(name)
      Captain::Runtime::ToolFailure.canonical_name(name)
    end

    def redis_key(action_id)
      "#{REDIS_KEY_PREFIX}:#{action_id}"
    end

    def conversation_index_key(account_id, conversation_id)
      "#{CONVERSATION_INDEX_PREFIX}:#{account_id}:#{conversation_id}"
    end

    def lock_key(action_id)
      "#{LOCK_PREFIX}:#{action_id}"
    end

    private

    def new_interception(tool:, tool_context:, arguments:, replaces: [])
      context = tool_context&.context || {}
      state = (tool_context&.state || context[:state] || {}).to_h.with_indifferent_access
      assistant = resolve_assistant(tool, state)
      account = assistant&.account || Account.find_by(id: state[:account_id])
      conversation = account&.conversations&.find_by(id: state.dig(:conversation, :id))
      normalized_args = arguments.to_h.deep_symbolize_keys
      tool_id = canonical_tool_name(tool.name)

      policy_or_scope_error = verify_policy_and_scope(tool, tool_context, normalized_args)
      return policy_or_scope_error if policy_or_scope_error

      booking = {}
      early_or_invalid = validate_domain_call(tool_id: tool_id, assistant: assistant, account: account, conversation: conversation,
                                              state: state, arguments: normalized_args, booking: booking)
      return early_or_invalid if early_or_invalid

      record = build_or_reuse_proposal(
        context: context, state: state, assistant: assistant, account: account, conversation: conversation, tool_id: tool_id,
        arguments: normalized_args, booking_key: booking_key(booking)
      )
      proposal_result(record, context, replaces)
    end

    # The answer of a new card for the agent, once the cards it replaces are withdrawn: the run's cards it was told to replace, the
    # run's booking cards of the same booking, and then the kept booking card of the same booking (in this order: a booking card of
    # the run that goes gives back the kept card it replaced, which the new card then replaces).
    def proposal_result(record, context, replaces)
      own = (Array(replaces).map(&:to_s) + replaced_booking_ids(context, record)).uniq - [record['action_id'].to_s]
      replaced = supersede_in_run!(context, own)
      replaced += supersede_kept!(context, record)
      render_interception_result(record, context, replaced)
    end

    # One booking is one patient with one specialist and one service (as the booking resolves them, see booking_person): a booking at
    # another date or time with the same three is a corrected booking, and its card replaces the earlier one; another patient,
    # specialist or service is another booking with a card of its own.
    def booking_key(booking)
      return if booking[:resource_id].blank? || booking[:person].blank?

      Digest::SHA256.hexdigest(JSON.generate([booking[:person], booking[:resource_id].to_s, booking[:service_id].to_s]))
    end

    # The patient of a booking as the booking resolves it, so that the same person is the same booking whatever details the model
    # passes this time (it rebuilds them from the chat in every suggestion): the person of the conversation when no patient is passed,
    # when the patient's card is the conversation contact or when the patient's name is the contact's; any other patient by first and
    # last name in letters only. The birth date, the IIN and the middle name are left out, and so is a card found by the IIN: a
    # corrected booking of the same relative may add or drop them.
    def booking_person(patient, patient_id:, conversation:)
      contact_person = "contact:#{conversation&.contact_id}"
      return contact_person if patient.blank? || (patient_id.present? && patient_id == conversation&.contact_id)

      names = patient.to_h.deep_symbolize_keys
      return contact_person if patient_id.blank? && conversation_person?(names, conversation&.contact)

      "name:#{name_letters(names[:first_name])} #{name_letters(names[:last_name])}"
    end

    # Whether the patient a booking names is the person of the conversation: the first and last name of the contact's card, or both
    # among the words of the contact's name (a contact named "Иван Петров" with no last name of its own).
    def conversation_person?(names, contact)
      person = [name_letters(names[:first_name]), name_letters(names[:last_name])]
      return false if contact.blank? || person.any?(&:blank?)

      recorded = Integrations::Medelement::AppointmentPatientIdentity.contact_names(contact)
      return true if person == [name_letters(recorded['first_name']), name_letters(recorded['last_name'])]

      (person - [contact.name, contact.last_name].join(' ').split.map { |word| name_letters(word) }).empty?
    end

    # A name in lower-case letters only, with the Kazakh letters and ё written as the Russian ones and no soft or hard sign, so that
    # "Серик кызы", "Сериккызы" and "Серікқызы" are one surname.
    def name_letters(value)
      value.to_s.unicode_normalize(:nfc).downcase.gsub(/[^\p{L}]/, '').gsub(NAME_LETTER_PATTERN, NAME_LETTER_FOLDS)
    end

    # The booking cards of the run (not the kept cards it lists) of the same booking as the new card.
    def replaced_booking_ids(context, record)
      return [] if record['booking_key'].blank?

      Array(context[CONTEXT_KEY]).filter_map do |item|
        action_id = item.to_h.stringify_keys['action_id'].to_s
        next if action_id == record['action_id'].to_s

        card = fetch_record(action_id)
        action_id if card && !kept?(card) && card['booking_key'] == record['booking_key']
      end
    end

    # Withdraws the cards of this run that the new card replaces: nothing ran, so each is rejected, leaves the run's list and is
    # remembered as superseded, and the draft and the operator see only the new card. Returns the withdrawn cards.
    def supersede_in_run!(context, action_ids)
      ids = own_run_card_ids(action_ids.compact_blank)
      return [] if ids.empty?

      replaced = withdraw_from_run!(context, ids)
      discard!(action_ids: ids, reason: SUPERSEDED_REASON)
      replaced
    end

    # A booking replaces the kept card of an earlier suggestion of the conversation for the same booking at another date or time (the
    # manager inserted or sent that draft, and its card still waits): one card per booking waits for the operator, the one the latest
    # draft names. The kept card comes back if the new card goes without the operator acting on it (see restore_replaced_kept!).
    # Returns the withdrawn cards.
    def supersede_kept!(context, record)
      kept = replaced_kept_records(record)
      return [] if kept.empty?

      ids = kept.map { |card| card['action_id'].to_s }
      update_record!(record.merge!('replaced_kept_ids' => (Array(record['replaced_kept_ids']) + ids).uniq))
      kept.each do |card|
        update_record!(card.merge('status' => REJECTED_STATUS, 'rejected_at' => Time.current.iso8601,
                                  'rejected_reason' => KEPT_SUPERSEDED_REASON, 'superseded_by' => record['action_id']))
      end
      withdraw_from_run!(context, ids)
      kept
    end

    def replaced_kept_records(record)
      return [] if record['booking_key'].blank?

      pending_records(record['account_id'], record['conversation_id']).select do |card|
        kept?(card) && card['action_id'].to_s != record['action_id'].to_s && card['booking_key'] == record['booking_key']
      end
    end

    # Takes withdrawn cards out of the run's list and remembers them as superseded, so that the draft, the result and the manager's
    # panel leave them out. Returns the cards the run listed.
    def withdraw_from_run!(context, ids)
      cards = context[CONTEXT_KEY].is_a?(Array) ? context[CONTEXT_KEY] : []
      replaced, listed = cards.partition { |item| ids.include?(item.to_h.stringify_keys['action_id'].to_s) }
      cards.replace(listed)
      context[SUPERSEDED_CONTEXT_KEY] = (Array(context[SUPERSEDED_CONTEXT_KEY]) + ids).uniq
      replaced
    end

    # Only a card that this run prepared is withdrawn; a card of an earlier suggestion that still waits for approval is not the run's.
    def own_run_card_ids(ids)
      control = Captain::ReplySuggestion::RunControl.current
      control ? ids & control.action_ids : ids
    end

    def resolve_assistant(tool, state)
      actor = tool.send(:assistant) if tool.respond_to?(:assistant, true)
      actor || Captain::Assistant.find_by(id: state[:assistant_id])
    end

    def verify_policy_and_scope(tool, tool_context, arguments)
      return unless tool.is_a?(Captain::Tools::BasePublicTool)

      tool.send(:ensure_tool_execution_allowed!)
      tool.send(:patient_scope_for, tool_context.state).authorize_public_tool!(tool.name, arguments, tool_context.state)
      nil
    rescue Captain::Tools::Agent::PatientScope::Denied
      if canonical_tool_name(tool.name).in?(APPOINTMENT_TOOLS)
        JSON.generate(
          success: false,
          reason: 'not_found',
          error_class: Captain::Tools::Agent::AppointmentResult::ERROR_CLASS_BUSINESS
        )
      else
        Captain::Tools::Agent::PatientScope::FAILURE
      end
    rescue ArgumentError => e
      business_failure(e.message, reason: 'validation_error')
    end

    # booking: filled with the patient, the specialist and the service a valid booking resolves to (see booking_key).
    def validate_domain_call(tool_id:, assistant:, account:, conversation:, state:, arguments:, booking: {})
      case tool_id
      when 'create_appointment'
        validate_create_appointment(assistant: assistant, account: account, conversation: conversation, arguments: arguments, booking: booking)
      when 'update_appointment'
        validate_update_appointment(assistant: assistant, account: account, conversation: conversation, arguments: arguments)
      when 'cancel_appointment'
        validate_cancel_appointment(assistant: assistant, account: account, conversation: conversation, arguments: arguments)
      when 'update_contact', 'update_my_contact'
        invalid_iin_failure(account, arguments) ||
          validate_generic_domain_call(tool_id: tool_id, account: account, conversation: conversation, state: state, arguments: arguments)
      else
        validate_generic_domain_call(tool_id: tool_id, account: account, conversation: conversation, state: state, arguments: arguments)
      end
    end

    def validate_create_appointment(assistant:, account:, conversation:, arguments:, booking: {})
      return business_failure('Scheduling is not available', reason: 'validation_error') unless assistant && account

      operation = Captain::Tools::Operations::AppointmentOperations.new(
        assistant: assistant, conversation: conversation, actor: assistant
      )
      operation.send(:ensure_feature_enabled!, 'scheduling', 'Scheduling is not enabled for this account')
      resource_id = operation.send(:resolve_agent_resource_id, arguments[:resource_id], arguments[:service_id])
      starts_at, ends_at = operation.send(
        :normalize_appointment_times, resource_id: resource_id, starts_at: arguments[:starts_at], ends_at: arguments[:ends_at]
      )
      validated_service = operation.send(
        :validate_booking_inputs!, starts_at: starts_at, ends_at: ends_at,
                                   duration_min: arguments[:duration_min], service_id: arguments[:service_id]
      )
      service_omitted = arguments[:service_id].blank?
      validated_service, arguments[:client_comment] = operation.send(
        :bookable_service_and_comment, resource_id, validated_service, arguments[:client_comment]
      )
      arguments[:service_id] = nil if arguments[:service_id].present? && validated_service.nil?
      service_id = validated_service&.id || (operation.send(:offered_service_id, resource_id) if service_omitted)
      custom_attrs = if arguments[:custom_attributes].present?
                       operation.send(:parsed_hash, arguments[:custom_attributes], field_name: 'custom_attributes')
                     end

      patient_id = conversation&.contact_id
      if arguments[:patient].present?
        patient_id = validate_patient_booking_arguments!(assistant: assistant, conversation: conversation, patient: arguments[:patient])
      end

      existing = operation.send(
        :existing_booking,
        { resource_id: resource_id, service_id: service_id, starts_at: starts_at, contact_id: patient_id }
      )
      return JSON.generate(Captain::Tools::Agent::AppointmentResult.already_booked(existing, action: 'create_appointment')) if existing.present?

      resource = account.scheduling_resources.find(resource_id)
      ensure_resource_available_for_scheduling!(resource)
      service = validated_service || (account.scheduling_services.find(service_id) if service_id.present?)
      validate_service_available_for_resource!(resource: resource, service: service) if service.present?
      validate_appointment_custom_attributes!(account: account, custom_attributes: custom_attrs, new_record: true)
      validate_slot_availability!(
        account: account, resource: resource, starts_at: starts_at, ends_at: ends_at,
        duration_min: arguments[:duration_min], service: service
      )

      booking.merge!(person: booking_person(arguments[:patient], patient_id: patient_id, conversation: conversation),
                     resource_id: resource.id, service_id: service&.id)
      nil
    rescue StandardError => e
      Captain::Tools::Agent::AppointmentResult.failure_output(e, account: account)
    end

    def validate_update_appointment(assistant:, account:, conversation:, arguments:)
      return business_failure('Scheduling is not available', reason: 'validation_error') unless assistant && account

      operation = Captain::Tools::Operations::AppointmentOperations.new(
        assistant: assistant, conversation: conversation, actor: assistant
      )
      operation.send(:ensure_feature_enabled!, 'scheduling', 'Scheduling is not enabled for this account')
      appointment = operation.send(
        :target_appointment,
        arguments[:appointment_id],
        appointment_access_token: arguments[:appointment_access_token],
        patient_confirmed: arguments[:patient_confirmed] == true
      )
      Scheduling::Appointments::MutationGuard.ensure_editable!(appointment)
      Scheduling::Appointments::MutationGuard.ensure_assignable!(arguments)

      starts_at, ends_at = operation.send(
        :normalize_appointment_times,
        resource_id: arguments[:resource_id] || appointment.resource_id,
        starts_at: arguments[:starts_at],
        ends_at: arguments[:ends_at]
      )
      validated_service = operation.send(
        :validate_booking_inputs!,
        starts_at: starts_at, ends_at: ends_at, duration_min: arguments[:duration_min],
        service_id: arguments[:service_id], appointment: appointment
      )
      validated_service, arguments[:client_comment] = operation.send(
        :bookable_service_and_comment, arguments[:resource_id] || appointment.resource_id,
        validated_service, arguments[:client_comment] || appointment.client_comment
      )
      arguments[:service_id] = nil if arguments[:service_id].present? && validated_service.nil?
      service_id = validated_service&.id
      params = build_update_comparison_params(arguments, starts_at: starts_at, ends_at: ends_at, service_id: service_id, operation: operation)
      if operation.send(:appointment_unchanged?, appointment, params)
        return JSON.generate(Captain::Tools::Agent::AppointmentResult.unchanged(appointment, action: 'update_appointment'))
      end

      resource = arguments[:resource_id].present? ? account.scheduling_resources.find(arguments[:resource_id]) : appointment.resource
      if arguments[:resource_id].present? && arguments[:resource_id].to_i != appointment.resource_id
        ensure_resource_available_for_scheduling!(resource)
      end
      validate_service_available_for_resource!(resource: resource, service: validated_service) if validated_service.present?
      if params.key?(:custom_attributes)
        validate_appointment_custom_attributes!(
          account: account, custom_attributes: params[:custom_attributes],
          current_attributes: appointment.custom_attributes, new_record: false
        )
      end

      interval_or_resource_changed = starts_at.present? || ends_at.present? || arguments[:duration_min].present? ||
                                     (arguments[:resource_id].present? && arguments[:resource_id].to_i != appointment.resource_id)
      if interval_or_resource_changed
        validate_slot_availability!(
          account: account,
          resource: resource,
          starts_at: starts_at || appointment.starts_at,
          ends_at: ends_at,
          duration_min: arguments[:duration_min] || (appointment.duration_min unless validated_service),
          service: arguments.key?(:service_id) ? validated_service : appointment.service,
          ignore_appointment_id: appointment.id
        )
      end

      nil
    rescue StandardError => e
      Captain::Tools::Agent::AppointmentResult.failure_output(e, account: account)
    end

    def build_update_comparison_params(arguments, starts_at:, ends_at:, service_id:, operation:)
      params = {}
      params[:resource_id] = arguments[:resource_id] unless arguments[:resource_id].nil?
      params[:service_id] = service_id if arguments.key?(:service_id)
      params[:starts_at] = starts_at unless starts_at.nil?
      params[:ends_at] = ends_at unless ends_at.nil?
      params[:duration_min] = arguments[:duration_min] unless arguments[:duration_min].nil?
      params[:appointment_type] = arguments[:appointment_type] unless arguments[:appointment_type].nil?
      params[:client_comment] = arguments[:client_comment] unless arguments[:client_comment].nil?
      if arguments[:custom_attributes].present?
        params[:custom_attributes] = operation.send(:parsed_hash, arguments[:custom_attributes], field_name: 'custom_attributes')
      end
      params
    end

    def validate_cancel_appointment(assistant:, account:, conversation:, arguments:)
      return business_failure('Scheduling is not available', reason: 'validation_error') unless assistant && account

      operation = Captain::Tools::Operations::AppointmentOperations.new(
        assistant: assistant, conversation: conversation, actor: assistant
      )
      operation.send(:ensure_feature_enabled!, 'scheduling', 'Scheduling is not enabled for this account')
      appointment = operation.send(
        :target_appointment,
        arguments[:appointment_id],
        appointment_access_token: arguments[:appointment_access_token],
        patient_confirmed: arguments[:patient_confirmed] == true
      )
      # Imported receptions are cancelled by ImportedProviderMutationService after approval.
      Scheduling::Appointments::MutationGuard.ensure_editable!(appointment) unless
        appointment.source == Scheduling::Appointments::MutationGuard::PROVIDER_SOURCE
      nil
    rescue StandardError => e
      Captain::Tools::Agent::AppointmentResult.failure_output(e, account: account)
    end

    def ensure_resource_available_for_scheduling!(resource)
      return if resource&.active? && !resource.deleted_from_scheduling?

      raise Scheduling::Error.new(
        code: 'RESOURCE_NOT_AVAILABLE_FOR_SCHEDULING',
        message: 'Specialist is not available for scheduling',
        status: :unprocessable_content
      )
    end

    # A recorded service-price link to the specialist is never required; only the price and the MedElement mapping are checked.
    def validate_service_available_for_resource!(resource:, service:)
      price = service.prices.find_by(resource_id: resource.id)
      resolved_price = price&.active? && price.price.to_i.positive? ? price.price : service.base_price
      if !service.active? || resolved_price.to_i <= 0
        raise Scheduling::Error.new(
          code: 'SERVICE_NOT_AVAILABLE_FOR_RESOURCE',
          message: 'Service is not available for the selected resource',
          status: :unprocessable_content
        )
      end

      return if resource.custom_attributes.to_h['medelement_specialist_code'].blank?

      return if service.custom_attributes.to_h['medelement_nomenclature_code'].present?

      # Nothing was written (a card is only prepared here), so the agent corrects the call in the same run: it retries without the
      # service (see AppointmentResult.service_unmapped_failure).
      raise Scheduling::Error.new(
        code: Captain::Tools::Agent::AppointmentResult::SERVICE_UNMAPPED_CODE,
        message: 'Selected services must be linked to Medelement',
        status: :unprocessable_content,
        details: { mutation_executed: false }
      )
    end

    def validate_appointment_custom_attributes!(account:, custom_attributes:, new_record:, current_attributes: {})
      catalog = Crm::FieldCatalog.new(account: account, entity_kind: 'appointment', context: 'booking_intake')
      return if catalog.definitions.blank?

      sanitized_current = current_attributes.to_h.deep_stringify_keys.except('service_ids', 'services')
      sanitized_incoming = custom_attributes&.to_h&.deep_stringify_keys&.except('service_ids', 'services', 'medelement_cabinet_code')
      catalog.resolve_custom_attributes(
        current_attributes: sanitized_current,
        incoming_attributes: sanitized_incoming,
        apply_defaults: new_record
      )
    end

    def validate_slot_availability!(account:, resource:, starts_at:, ends_at: nil, duration_min: nil, service: nil, ignore_appointment_id: nil)
      return if resource.blank? || starts_at.blank?

      start_time = if starts_at.is_a?(Time) || starts_at.is_a?(ActiveSupport::TimeWithZone)
                     starts_at
                   else
                     Scheduling::InputValidation.datetime(
                       starts_at.to_s, field_name: 'starts_at'
                     )
                   end
      # The same length slot search offers and the booking writes (Scheduling::VisitDuration): the service's own length, or for a
      # MedElement service the history median in whole slots of the specialist. service.duration_min is not it for a MedElement
      # service, it is the column default.
      resolved_duration = if duration_min.present?
                            Scheduling::IntegerNumericNormalizer.normalize_or_zero(duration_min, field_name: :duration_min)
                          else
                            visit_minutes = Scheduling::VisitDuration.minutes(resource: resource, service: service).to_i
                            visit_minutes.positive? ? visit_minutes : Scheduling::VisitDuration.slot_minutes(resource)
                          end
      end_time = if ends_at.present?
                   if ends_at.is_a?(Time) || ends_at.is_a?(ActiveSupport::TimeWithZone)
                     ends_at
                   else
                     Scheduling::InputValidation.datetime(ends_at.to_s,
                                                          field_name: 'ends_at')
                   end
                 else
                   start_time + resolved_duration.minutes
                 end

      medelement = resource.custom_attributes.to_h['medelement_specialist_code'].present?
      if !medelement && (resource.work_rules.active.exists? || resource.workday_overrides.exists?)
        service_check = Scheduling::AvailabilityService.new(
          resource: resource,
          from: start_time.beginning_of_day - 1.day,
          to: end_time.end_of_day + 1.day,
          holidays: account.scheduling_holidays.ordered.to_a,
          workday_overrides: resource.workday_overrides.where(date: (start_time.to_date - 2)..(end_time.to_date + 2)).to_a,
          time_offs: account.scheduling_time_offs.where(resource_id: [nil, resource.id]).where('starts_at < ? AND ends_at > ?', end_time,
                                                                                               start_time).to_a,
          appointments: account.scheduling_appointments.where(resource_id: resource.id).where('starts_at < ? AND ends_at > ?', end_time,
                                                                                              start_time).to_a,
          ignore_appointment_id: ignore_appointment_id
        )
        result = service_check.availability_result(starts_at: start_time, ends_at: end_time)
        unless result.available?
          raise Scheduling::Error.new(
            code: result.code,
            message: result.message,
            status: result.code == 'VALIDATION_ERROR' ? :unprocessable_content : :conflict
          )
        end
        return
      end

      if account.scheduling_time_offs.where(resource_id: [nil, resource.id]).where('starts_at < ? AND ends_at > ?', end_time, start_time).exists?
        raise Scheduling::Error.new(code: 'BLOCKED_BY_VACATION', message: 'Appointment overlaps blocked time', status: :conflict)
      end

      overlapping = account.scheduling_appointments
                           .where(resource_id: resource.id)
                           .where('starts_at < ? AND ends_at > ?', end_time, start_time)
                           .to_a
      conflict = overlapping.any? do |appt|
        appt.id != ignore_appointment_id &&
          (appt.status != 'cancelled' || Integrations::Medelement::LocalCancellation.provider_occupied?(appt))
      end
      return unless conflict

      raise Scheduling::Error.new(code: 'SLOT_CONFLICT', message: 'Slot is already occupied', status: :conflict)
    end

    def validate_patient_booking_arguments!(assistant:, conversation:, patient:)
      context = Captain::Tools::Agent::PatientBookingContext.new(
        assistant: assistant, conversation: conversation, patient: patient
      )
      patient_hash = context.send(:patient)
      raise ArgumentError, 'Current conversation is not available' unless conversation&.account_id == assistant.account_id
      raise ArgumentError, 'Patient first and last name are required' if patient_hash[:first_name].blank? || patient_hash[:last_name].blank?
      raise ArgumentError, 'Invalid patient IIN' if patient_hash[:iin].present? && !Scheduling::IinValidator.valid?(patient_hash[:iin])

      context.send(:validate_birth_date!)
      existing = context.send(:existing_patient)
      existing&.id
    end

    def validate_generic_domain_call(tool_id:, account:, conversation:, state:, arguments:)
      return business_failure('Account context is not available', reason: 'validation_error') unless account

      case tool_id
      when 'create_deal', 'update_deal', 'transition_deal_stage', 'create_task', 'update_task', 'change_task_status'
        return business_failure('CRM is not enabled for this account', reason: 'validation_error') unless account.feature_enabled?('crm')
      end

      if tool_id.in?(%w[update_deal transition_deal_stage])
        deal_id = arguments[:deal_id].presence || state.dig(:deal, :id)
        deal = Captain::ContextFields.deal_for(account: account, conversation: conversation, deal_id: deal_id)
        return business_failure('Current deal is not available', reason: 'not_found') if deal.blank?
      elsif tool_id.in?(%w[update_task change_task_status])
        task_id = arguments[:task_id].presence || state.dig(:task, :id)
        task = if task_id.present?
                 account.crm_tasks.find_by(id: task_id)
               else
                 Captain::ContextFields.task_for(account: account, conversation: conversation)
               end
        return business_failure('Current task is not available', reason: 'not_found') if task.blank?
      end
      nil
    end

    # A card that writes the IIN of the patient is prepared only for an IIN: 12 digits with the check digit, never a phone number (the
    # eval of 27.10 raised a card to write a payment phone number as the ID number). Only for the accounts that identify patients by it.
    def invalid_iin_failure(account, arguments)
      return unless Scheduling::IinValidator.in_use?(account)

      Scheduling::IinValidator.require_valid_in!(
        identifier: arguments[:identifier].presence || arguments[:iin], custom_attributes: arguments[:custom_attributes]
      )
      nil
    rescue Scheduling::Error => e
      business_failure(e.message, reason: 'validation_error')
    end

    def business_failure(message, reason: 'validation_error')
      Captain::ToolResult.failure(
        error: message,
        retryable: false,
        data: { error_class: Captain::Runtime::ToolFailure::BUSINESS, reason: reason, mutation_executed: false },
        audit: { failure_stage: 'tool_arguments', failure_reason: 'invalid_tool_arguments', mutation_executed: false }
      )
    end

    # booking_key: the booking of a create_appointment card (see booking_key), which a corrected booking replaces.
    def build_or_reuse_proposal(context:, state:, assistant:, account:, conversation:, tool_id:, arguments:, booking_key: nil)
      digest = compute_digest(account_id: account&.id, conversation_id: conversation&.id, tool_name: tool_id, arguments: arguments)
      reusable = own_proposal(context, digest) || kept_proposal(context, account&.id, conversation&.id, digest)
      return reusable if reusable

      presentation = build_presentation(
        tool_id: tool_id, assistant: assistant, account: account, conversation: conversation, state: state, arguments: arguments
      )
      target_appt = if tool_id.in?(%w[update_appointment cancel_appointment]) && arguments[:appointment_access_token].present?
                      resolve_target_appointment_quietly(assistant: assistant, conversation: conversation, arguments: arguments)
                    end
      record = {
        'action_id' => SecureRandom.uuid,
        'account_id' => account&.id,
        'conversation_id' => conversation&.id,
        'conversation_display_id' => conversation&.display_id || state.dig(:conversation, :display_id),
        'assistant_id' => assistant&.id,
        'tool_name' => tool_id,
        'status' => PENDING_STATUS,
        'digest' => digest,
        'booking_key' => booking_key,
        'title' => presentation[:title],
        'description' => presentation[:description],
        'details' => presentation[:details],
        'agent' => agent_summary(assistant),
        # The suggestion request and the manager the card was prepared for (a later suggestion replaces it, see discard_superseded!).
        'suggestion_request_id' => Captain::ReplySuggestion::RunControl.current&.request_id,
        'user_id' => Current.user&.id,
        'arguments' => JSON.parse(JSON.generate(arguments)),
        'appointment_snapshot' => (appointment_access_snapshot(target_appt) if target_appt),
        'created_at' => Time.current.iso8601
      }.compact

      store_record!(record)
      (context[CONTEXT_KEY] ||= []) << public_payload(record)
      record
    end

    # The card this run already prepared for the same action.
    def own_proposal(context, digest)
      existing = Array(context[CONTEXT_KEY]).find { |item| item['digest'] == digest }
      fetch_record(existing['action_id']).presence if existing
    end

    # The card of the same action of a suggestion the manager inserted or sent, which still waits for approval: the run shows that
    # card instead of a second one (it is not the run's own: a run that does not finish leaves it as it is).
    def kept_proposal(context, account_id, conversation_id, digest)
      kept = pending_records(account_id, conversation_id).find { |record| kept?(record) && record['digest'] == digest }
      return unless kept

      (context[CONTEXT_KEY] ||= []) << public_payload(kept)
      kept
    end

    def appointment_access_snapshot(appointment)
      return unless appointment

      {
        'appointment_id' => appointment.id,
        'patient_id' => appointment.patient_contact_id || appointment.contact_id,
        'resource_id' => appointment.resource_id,
        'starts_at' => appointment.starts_at&.utc&.iso8601(6),
        'ends_at' => appointment.ends_at&.utc&.iso8601(6),
        'updated_at' => appointment.updated_at&.utc&.iso8601(6)
      }
    end

    def render_interception_result(record, context = {}, replaced = [])
      JSON.generate(
        success: true,
        status: 'pending_operator_approval',
        operator_approval_required: true,
        action_id: record['action_id'],
        action: record['tool_name'],
        title: record['title'],
        summary: record['description'],
        details: record['details'],
        message: approval_message(record, context, replaced)
      )
    end

    # Exactly what waits for the operator: this card and its kind, the card it replaced, and every card of the run with its details,
    # so the draft names no other action and no other time.
    def approval_message(record, context, replaced = [])
      scope = APPROVAL_SCOPES.fetch(record['tool_name'].to_s, NOT_APPOINTMENT_SCOPE)
      replaced_labels = replaced.filter_map { |item| card_label(item.to_h.stringify_keys) }
      replaced_note = "It replaces #{replaced_labels.join(', ')}: that card is withdrawn, the operator no longer sees it. " if replaced_labels.any?
      "NOT executed. Waiting for operator approval (Allow / Deny): «#{record['title']}» (#{scope}). #{replaced_note}" \
        "Cards waiting in this run: #{waiting_card_labels(record, context).join(', ')}. " \
        'Draft the reply without saying that any of them is done; mention a booking, change or cancellation only when its card is listed.'
    end

    def waiting_card_labels(record, context)
      cards = (Array(context.to_h[CONTEXT_KEY]) + [record]).map { |item| item.to_h.stringify_keys }
      cards.uniq { |item| item['action_id'].presence || item['digest'] }.filter_map { |item| card_label(item) }
    end

    # "«Записать на приём» (create_appointment: Специалист: Д-р Смит • Дата и время: ...)": the title, the tool and the details of a
    # card, so that two cards of one tool are told apart.
    def card_label(item)
      return if item['title'].blank?

      details = item['description'].presence unless item['description'].to_s == item['title'].to_s
      "«#{item['title']}» (#{[item['tool_name'], details].compact_blank.join(': ')})"
    end

    def agent_summary(assistant)
      return { 'name' => 'AI' } if assistant.blank?

      {
        'id' => assistant.id,
        'name' => assistant.name.to_s.strip.presence || assistant.agent_name,
        'avatar_url' => (assistant.avatar_url.presence if assistant.respond_to?(:avatar_url))
      }.compact
    end

    def build_presentation(tool_id:, assistant:, account:, conversation:, state:, arguments:)
      title = ACTION_TITLES[tool_id] || Captain::ToolRegistry.definition_for(tool_id)&.title || tool_id.to_s.humanize
      details = build_details(
        tool_id: tool_id, assistant: assistant, account: account, conversation: conversation, state: state, arguments: arguments
      )
      description = details.map { |item| "#{item['label']}: #{item['value']}" }.join(' • ')
      { title: title, description: description.presence || title, details: details }
    end

    def build_details(tool_id:, assistant:, account:, conversation:, state:, arguments:)
      case tool_id
      when 'create_appointment', 'update_appointment', 'cancel_appointment'
        build_appointment_details(tool_id: tool_id, assistant: assistant, account: account, conversation: conversation, arguments: arguments)
      when 'create_deal', 'update_deal', 'transition_deal_stage'
        build_deal_details(account: account, arguments: arguments)
      when 'create_task', 'update_task', 'change_task_status'
        build_task_details(arguments: arguments)
      when 'update_contact', 'update_my_contact'
        build_contact_details(arguments: arguments)
      when 'add_private_note', 'add_contact_note'
        build_note_details(arguments: arguments)
      else
        build_generic_details(_state: state, arguments: arguments)
      end
    end

    def build_appointment_details(tool_id:, assistant:, account:, conversation:, arguments:)
      details = []
      unless tool_id == 'create_appointment'
        appointment = resolve_target_appointment_quietly(assistant: assistant, conversation: conversation, arguments: arguments)
      end
      resource_id = arguments[:resource_id].presence || appointment&.resource_id
      resource = account&.scheduling_resources&.find_by(id: resource_id) if resource_id.present?
      service_id = arguments.key?(:service_id) ? arguments[:service_id] : appointment&.service_id
      service = account&.scheduling_services&.find_by(id: service_id) if service_id.present?

      details << { 'label' => 'Специалист', 'value' => resource.name } if resource&.name.present?
      details << { 'label' => 'Услуга', 'value' => service.name } if service&.name.present?

      formatted_time = format_appointment_slot(
        starts_at: arguments[:starts_at].presence || appointment&.starts_at,
        ends_at: arguments[:ends_at].presence || (appointment&.ends_at if arguments[:starts_at].blank?),
        duration_min: arguments[:duration_min],
        resource: resource,
        account: account
      )
      details << { 'label' => 'Дата и время', 'value' => formatted_time } if formatted_time.present?

      patient_label = extract_patient_label(arguments[:patient], conversation: conversation, appointment: appointment)
      details << { 'label' => 'Пациент', 'value' => patient_label } if patient_label.present?
      details << { 'label' => 'Комментарий', 'value' => arguments[:client_comment].to_s.strip } if arguments[:client_comment].present?
      details
    end

    def resolve_target_appointment_quietly(assistant:, conversation:, arguments:)
      return unless assistant && conversation

      operation = Captain::Tools::Operations::AppointmentOperations.new(
        assistant: assistant, conversation: conversation, actor: assistant
      )
      operation.send(
        :target_appointment,
        arguments[:appointment_id],
        appointment_access_token: arguments[:appointment_access_token],
        patient_confirmed: arguments[:patient_confirmed] == true
      )
    rescue StandardError
      nil
    end

    def format_appointment_slot(starts_at:, ends_at:, duration_min:, resource:, account:)
      return if starts_at.blank?

      zone_name = Captain::Tools::Agent::AppointmentTimeInput.timezone(
        resource_timezone: resource&.timezone,
        account_timezone: account&.reporting_timezone
      )
      start_time = Captain::Tools::Agent::AppointmentTimeInput.parse(starts_at, timezone: zone_name, field_name: 'starts_at')
      end_time = if ends_at.present?
                   Captain::Tools::Agent::AppointmentTimeInput.parse(ends_at, timezone: zone_name, field_name: 'ends_at')
                 elsif duration_min.present? && duration_min.to_i.positive?
                   start_time + duration_min.to_i.minutes
                 end

      date_str = start_time.strftime('%d.%m.%Y')
      time_str = end_time ? "#{start_time.strftime('%H:%M')}–#{end_time.strftime('%H:%M')}" : start_time.strftime('%H:%M')
      "#{date_str}, #{time_str}"
    rescue StandardError
      starts_at.to_s
    end

    def extract_patient_label(patient_arg, conversation:, appointment:)
      if patient_arg.is_a?(Hash)
        hash = patient_arg.with_indifferent_access
        full_name = [hash[:last_name], hash[:first_name], hash[:middle_name]].filter_map { |part| part.to_s.strip.presence }.join(' ')
        phone = hash[:phone].to_s.strip.presence
        return [full_name.presence, phone].compact.join(', ') if full_name.present? || phone.present?
      end

      patient_contact = appointment&.patient_contact || appointment&.contact || conversation&.contact
      return unless patient_contact

      [patient_contact.name.to_s.strip.presence, patient_contact.phone_number.to_s.strip.presence].compact.join(', ').presence
    end

    def build_deal_details(account:, arguments:)
      details = []
      details << { 'label' => 'Название', 'value' => arguments[:title].to_s.strip } if arguments[:title].present?
      if arguments[:stage_id].present? && account
        stage = account.crm_stages.find_by(id: arguments[:stage_id])
        details << { 'label' => 'Этап', 'value' => stage&.name || "##{arguments[:stage_id]}" }
      end
      details << { 'label' => 'Сумма', 'value' => arguments[:amount].to_s } if arguments[:amount].present?
      details << { 'label' => 'Статус', 'value' => arguments[:status].to_s } if arguments[:status].present?
      details
    end

    def build_task_details(arguments:)
      details = []
      details << { 'label' => 'Задача', 'value' => arguments[:title].to_s.strip } if arguments[:title].present?
      details << { 'label' => 'Статус', 'value' => arguments[:status].to_s.strip } if arguments[:status].present?
      details << { 'label' => 'Срок', 'value' => arguments[:due_at].to_s.strip } if arguments[:due_at].present?
      details
    end

    def build_contact_details(arguments:)
      details = []
      details << { 'label' => 'Имя', 'value' => arguments[:name].to_s.strip } if arguments[:name].present?
      details << { 'label' => 'Телефон', 'value' => arguments[:phone_number].to_s.strip } if arguments[:phone_number].present?
      details << { 'label' => 'Email', 'value' => arguments[:email].to_s.strip } if arguments[:email].present?
      details
    end

    def build_note_details(arguments:)
      content = (arguments[:content] || arguments[:note]).to_s.strip
      return [] if content.blank?

      [{ 'label' => 'Текст', 'value' => content.truncate(160) }]
    end

    def build_generic_details(_state:, arguments:)
      arguments.except(:appointment_access_token, :idempotency_key).filter_map do |key, value|
        next if value.blank?

        formatted = value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
        { 'label' => key.to_s.humanize, 'value' => formatted.truncate(140) }
      end.first(5)
    end

    # The fingerprint of an action: the same action in the same conversation is one card, whichever agent prepared it (the router may
    # give the dialog to another agent between two suggestions, and two parts of a council may prepare the same action).
    def compute_digest(account_id:, conversation_id:, tool_name:, arguments:)
      payload = {
        account_id: account_id.to_i,
        conversation_id: conversation_id.to_i,
        tool_name: tool_name.to_s,
        arguments: canonical_json(arguments)
      }
      Digest::SHA256.hexdigest(JSON.generate(payload))
    end

    def canonical_json(value)
      case value
      when Hash
        value.to_h.stringify_keys.sort.to_h.transform_values { |nested| canonical_json(nested) }
      when Array
        value.map { |nested| canonical_json(nested) }
      else
        value
      end
    end
  end

  def initialize(account:, user:, conversation_display_id: nil)
    @account = account
    @user = user
    @conversation_display_id = conversation_display_id
  end

  def approve!(action_id:, digest: nil)
    with_action_lock(action_id) do
      record = load_authorized_record!(action_id)
      return self.class.public_payload(record) if record['status'] == APPROVED_STATUS

      validate_approvable_state!(record, digest: digest)
      conversation = find_authorized_conversation!(record)
      assistant = resolve_execution_assistant!(record, conversation)
      execute_approved_action!(record: record, conversation: conversation, assistant: assistant)
    end
  end

  def reject!(action_id:)
    with_action_lock(action_id) do
      record = load_authorized_record!(action_id)
      return self.class.public_payload(record) if record['status'] == REJECTED_STATUS
      raise InvalidStateError, 'Action was already approved and executed' if record['status'] == APPROVED_STATUS

      find_authorized_conversation!(record)
      record['status'] = REJECTED_STATUS
      record['rejected_at'] = Time.current.iso8601
      record['rejected_by_id'] = @user&.id
      record['rejected_by_name'] = @user&.name
      self.class.store_record!(record)
      restore_kept_after_denial!(record)
      publish_approval_event(record, outcome: REJECTED_STATUS)
      self.class.public_payload(record)
    end
  end

  private

  # A denied card whose draft the manager never inserted or sent gives back the kept card it replaced: the patient read that time, and
  # nothing else would book it. A denied kept card was the time the patient read last, so the card it replaced stays withdrawn.
  def restore_kept_after_denial!(record)
    self.class.restore_replaced_kept!(record) unless self.class.kept?(record)
  end

  def load_authorized_record!(action_id)
    record = self.class.fetch_record(action_id)
    raise NotFoundError, 'Proposed action not found or expired' if record.blank?
    raise NotFoundError, 'Proposed action not found' if record['account_id'].to_i != @account.id

    if @conversation_display_id.present? &&
       record['conversation_display_id'].present? &&
       record['conversation_display_id'].to_i != @conversation_display_id.to_i
      raise InvalidStateError, 'Proposed action does not match the current conversation'
    end

    record
  end

  # A card that a corrected card replaced is never executed: approving it as well would book the same visit twice.
  def validate_approvable_state!(record, digest: nil)
    raise InvalidStateError, 'Action was replaced by a corrected card; approve the card that replaced it' if self.class.superseded?(record)
    raise InvalidStateError, 'Action was already rejected by the operator' if record['status'] == REJECTED_STATUS
    raise InvalidStateError, 'Action is currently executing' if record['status'] == EXECUTING_STATUS

    return unless digest.present? && record['digest'].present? && record['digest'] != digest.to_s

    raise InvalidStateError, 'Action parameters do not match the approved proposal'
  end

  def find_authorized_conversation!(record)
    accessible_scope = Conversations::PermissionFilterService.new(
      @account.conversations,
      @user,
      @account
    ).perform
    conversation = if record['conversation_id'].present?
                     accessible_scope.find_by(id: record['conversation_id'])
                   elsif record['conversation_display_id'].present?
                     accessible_scope.find_by(display_id: record['conversation_display_id'])
                   end
    raise ForbiddenError, 'You do not have access to this conversation' if conversation.blank?

    conversation
  end

  # The card is executed by the agent that prepared it, and by nobody else. When that agent is switched off or deleted the card is
  # stale: the manager asks the AI again.
  def resolve_execution_assistant!(record, _conversation)
    assistant = @account.captain_assistants.entry_eligible.find_by(id: record['assistant_id']) if record['assistant_id'].present?
    raise InvalidStateError, I18n.t('captain.reply_suggestion.errors.action_agent_unavailable') if assistant.blank?

    assistant
  end

  def execute_approved_action!(record:, conversation:, assistant:)
    definition = Captain::ToolRegistry.definition_for(record['tool_name'])
    raise InvalidStateError, "Tool '#{record['tool_name']}' is not available" unless definition&.agent_tool_class

    tool = definition.agent_tool_class.new(assistant)
    record['status'] = EXECUTING_STATUS
    record.delete('error_message')
    self.class.store_record!(record)

    tool_context = build_execution_tool_context(assistant: assistant, conversation: conversation)
    arguments = record['arguments'].to_h.deep_symbolize_keys
    refresh_appointment_access_token!(arguments: arguments, record: record, assistant: assistant, conversation: conversation)
    previous_actor = Current.executed_by
    Current.executed_by = @user || assistant

    raw_result = Llm::EventBus.with_context(user_id: @user&.id, account_id: @account.id, conversation_id: conversation.id) do
      tool.execute(tool_context, **arguments)
    end

    if Captain::Runtime::ToolFailure.failure?(raw_result)
      error_message = extract_failure_message(raw_result)
      record['status'] = FAILED_STATUS
      record['failed_at'] = Time.current.iso8601
      record['error_message'] = error_message
      self.class.store_record!(record)
      publish_approval_event(record, outcome: FAILED_STATUS, error_message: error_message)
      raise ExecutionError.new(error_message, action: self.class.public_payload(record))
    end

    record_done_in_session(record: record, conversation: conversation, tool: tool, arguments: arguments, result: raw_result)
    record['status'] = APPROVED_STATUS
    record['approved_at'] = Time.current.iso8601
    record['approved_by_id'] = @user&.id
    record['approved_by_name'] = @user&.name
    record['result_summary'] = extract_result_summary(record['tool_name'], raw_result)
    self.class.store_record!(record)
    publish_approval_event(record, outcome: APPROVED_STATUS)
    self.class.public_payload(record)
  rescue ExecutionError
    raise
  rescue StandardError => e
    record['status'] = FAILED_STATUS
    record['failed_at'] = Time.current.iso8601
    record['error_message'] = e.message
    self.class.store_record!(record)
    publish_approval_event(record, outcome: FAILED_STATUS, error_message: e.message)
    raise ExecutionError.new(e.message, action: self.class.public_payload(record))
  ensure
    Current.executed_by = previous_actor
  end

  def refresh_appointment_access_token!(arguments:, record:, assistant:, conversation:)
    return if arguments[:appointment_access_token].blank?

    snapshot = record['appointment_snapshot'].to_h
    return if snapshot.blank?

    appointment_id = arguments[:appointment_id].presence || snapshot['appointment_id']
    appointment = @account.scheduling_appointments.find_by(id: appointment_id)
    return unless appointment

    current_snapshot = self.class.send(:appointment_access_snapshot, appointment)
    return unless current_snapshot == snapshot

    arguments[:appointment_access_token] = Captain::Tools::Agent::AppointmentAccess.issue(
      assistant: assistant,
      conversation: conversation,
      appointment: appointment
    )
  end

  def build_execution_tool_context(assistant:, conversation:)
    runner_service = Captain::Assistant::AgentRunnerService.new(
      assistant: assistant,
      conversation: conversation,
      source: 'operator_approved_suggestion'
    )
    state = runner_service.send(:build_state)
    run_context = Captain::Runtime::RunContext.new(
      {
        state: state,
        current_agent: assistant.agent_name,
        acting_assistant_id: assistant.id
      }
    )
    Captain::Runtime::ToolContext.new(run_context: run_context)
  end

  def record_done_in_session(record:, conversation:, tool:, arguments:, result:)
    done = Captain::DoneActions.entry(
      tool_name: tool.name,
      arguments: arguments,
      result: result,
      request: "operator_approval:#{record['action_id']}"
    )
    return if done.blank?

    session = Captain::Conversation::AgentSession.new(conversation: conversation)
    session.change do |data|
      data['done'] = Captain::DoneActions.remember(data['done'], done.deep_stringify_keys)
    end
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][ActionApprovalService] Failed to record done action in session: #{e.class}: #{e.message}")
  end

  def extract_failure_message(raw_result)
    normalized = Captain::ToolResult.normalize(raw_result)
    return normalized[:error].to_s if normalized[:error].present?

    facts = Captain::Runtime::ToolFailure.facts(raw_result)
    facts['message'].presence || facts['error'].presence || facts['reason'].presence || 'Failed to execute action'
  end

  def extract_result_summary(tool_name, raw_result)
    facts = Captain::Runtime::ToolFailure.facts(raw_result)
    case tool_name.to_s
    when 'create_appointment', 'update_appointment'
      date_time = [facts['local_date'], facts['local_time']].compact_blank.join(', ')
      specialist = facts['doctor_name'].presence ||
                   facts['specialist_name'].presence ||
                   facts.dig('appointment', 'resource_name')
      [specialist, date_time].compact_blank.join(' — ').presence || 'Выполнено'
    when 'cancel_appointment'
      'Запись отменена'
    else
      facts['message'].to_s.presence || 'Выполнено'
    end
  rescue StandardError
    'Выполнено'
  end

  def publish_approval_event(record, outcome:, error_message: nil)
    Llm::EventBus.publish(
      'copilot.action_approval',
      feature: 'reply_suggestion',
      runtime_mode: 'captain_task',
      status: outcome,
      account_id: @account.id,
      user_id: @user&.id,
      user_name: @user&.name,
      assistant_id: record['assistant_id'],
      conversation_id: record['conversation_id'],
      conversation_display_id: record['conversation_display_id'],
      action_id: record['action_id'],
      tool_name: record['tool_name'],
      error_message: error_message
    )
  rescue StandardError
    nil
  end

  def with_action_lock(action_id)
    key = self.class.lock_key(action_id)
    token = SecureRandom.uuid
    acquired = Redis::Alfred.set(key, token, nx: true, ex: LOCK_TTL)
    raise InvalidStateError, 'Action is currently being processed' unless acquired

    yield
  ensure
    if defined?(acquired) && acquired
      current = Redis::Alfred.get(key)
      Redis::Alfred.delete(key) if current == token
    end
  end
end
