class Captain::ContextFields
  FIELD_REFERENCE_REGEX = %r{\[([^\]]+)\]\(field://([^)]+)\)}
  SCOPES = %i[contact conversation deal task appointment].freeze
  CONTACT_STATE_ATTRIBUTES = %i[
    id name email phone_number identifier contact_type
    custom_attributes additional_attributes
  ].freeze
  CONVERSATION_STATE_ATTRIBUTES = %i[
    id display_id inbox_id contact_id status priority
    label_list custom_attributes additional_attributes
  ].freeze
  DEAL_STATE_ATTRIBUTES = %i[
    id title description amount currency expected_close_on win_probability
    closed_at external_ref pipeline_id stage_id owner_id creator_id team_id company_id
    originating_conversation_id pipeline_name stage_name owner_name creator_name
    team_name company_name custom_attributes
  ].freeze
  TASK_STATE_ATTRIBUTES = %i[
    id title description activity_type outcome due_at start_at priority completed_at external_ref
    status_id assignee_id creator_id team_id deal_id originating_conversation_id
    status_name assignee_name creator_name team_name deal_title custom_attributes
  ].freeze
  APPOINTMENT_STATE_ATTRIBUTES = %i[
    id resource_id resource_name contact_id service_id company_id conversation_id created_by_id
    starts_at ends_at duration_min status appointment_type
    client_name client_phone client_identifier client_birth_date client_gender
    client_comment source external_ref payment_status
    service_name_snapshot service_type_snapshot service_duration_min_snapshot service_amount
    compensation_type_snapshot compensation_value_snapshot compensation_percent_snapshot
    prepaid_amount prepaid_payment_method settlement_amount settlement_payment_method
    start_date start_time end_date end_time
    custom_attributes
  ].freeze
  COMMUNICATION_THREAD_CHANNEL_KEYS = %i[
    conversation_id inbox_id inbox_name contact_inbox_id channel medium provider status
    can_reply can_send_text requires_template reply_window_open reply_window_closes_at
    reauthorization_required disabled disabled_reason primary channel_key
  ].freeze

  CONTACT_FIELD_DEFINITIONS = [
    { key: 'id', title: 'Contact ID', description: 'contact.id' },
    { key: 'name', title: 'Name', description: 'contact.name' },
    { key: 'email', title: 'Email', description: 'contact.email' },
    { key: 'phone_number', title: 'Phone Number', description: 'contact.phone_number' },
    { key: 'identifier', title: 'Identifier', description: 'contact.identifier' },
    { key: 'contact_type', title: 'Contact Type', description: 'contact.contact_type' }
  ].freeze

  CONVERSATION_FIELD_DEFINITIONS = [
    { key: 'id', title: 'Conversation Record ID', description: 'conversation.id' },
    { key: 'display_id', title: 'Conversation ID', description: 'conversation.display_id' },
    { key: 'inbox_id', title: 'Inbox ID', description: 'conversation.inbox_id' },
    { key: 'contact_id', title: 'Contact ID', description: 'conversation.contact_id' },
    { key: 'status', title: 'Status', description: 'conversation.status' },
    { key: 'priority', title: 'Priority', description: 'conversation.priority' },
    { key: 'label_list', title: 'Labels', description: 'conversation.label_list' }
  ].freeze
  DEAL_FIELD_DEFINITIONS = [
    { key: 'id', title: 'Deal ID', description: 'deal.id' },
    { key: 'title', title: 'Title', description: 'deal.title' },
    { key: 'description', title: 'Description', description: 'deal.description' },
    { key: 'amount', title: 'Amount', description: 'deal.amount (whole major currency units; 200 means 200, not 20000)' },
    { key: 'currency', title: 'Currency', description: 'deal.currency' },
    { key: 'expected_close_on', title: 'Expected Close Date', description: 'deal.expected_close_on' },
    { key: 'win_probability', title: 'Win Probability', description: 'deal.win_probability' },
    { key: 'closed_at', title: 'Closed At', description: 'deal.closed_at' },
    { key: 'external_ref', title: 'External Reference', description: 'deal.external_ref' },
    { key: 'pipeline_id', title: 'Pipeline ID', description: 'deal.pipeline_id' },
    { key: 'pipeline_name', title: 'Pipeline Name', description: 'deal.pipeline_name' },
    { key: 'stage_id', title: 'Stage ID', description: 'deal.stage_id' },
    { key: 'stage_name', title: 'Stage Name', description: 'deal.stage_name' },
    { key: 'owner_id', title: 'Owner User ID', description: 'deal.owner_id' },
    { key: 'owner_name', title: 'Owner Name', description: 'deal.owner_name' },
    { key: 'creator_id', title: 'Created By User ID', description: 'deal.creator_id' },
    { key: 'creator_name', title: 'Creator Name', description: 'deal.creator_name' },
    { key: 'team_id', title: 'Team ID', description: 'deal.team_id' },
    { key: 'team_name', title: 'Team Name', description: 'deal.team_name' },
    { key: 'company_id', title: 'Company ID', description: 'deal.company_id' },
    { key: 'company_name', title: 'Company Name', description: 'deal.company_name' },
    { key: 'originating_conversation_id', title: 'Conversation ID', description: 'deal.originating_conversation_id' }
  ].freeze
  TASK_FIELD_DEFINITIONS = [
    { key: 'id', title: 'Task ID', description: 'task.id' },
    { key: 'title', title: 'Title', description: 'task.title' },
    { key: 'description', title: 'Description', description: 'task.description' },
    { key: 'activity_type', title: 'Task Type', description: 'task.activity_type' },
    { key: 'outcome', title: 'Outcome', description: 'task.outcome' },
    { key: 'due_at', title: 'Due At', description: 'task.due_at' },
    { key: 'start_at', title: 'Start At', description: 'task.start_at' },
    { key: 'priority', title: 'Priority', description: 'task.priority' },
    { key: 'completed_at', title: 'Completed At', description: 'task.completed_at' },
    { key: 'external_ref', title: 'External Reference', description: 'task.external_ref' },
    { key: 'status_id', title: 'Status ID', description: 'task.status_id' },
    { key: 'status_name', title: 'Status Name', description: 'task.status_name' },
    { key: 'assignee_id', title: 'Assignee User ID', description: 'task.assignee_id' },
    { key: 'assignee_name', title: 'Assignee Name', description: 'task.assignee_name' },
    { key: 'creator_id', title: 'Created By User ID', description: 'task.creator_id' },
    { key: 'creator_name', title: 'Creator Name', description: 'task.creator_name' },
    { key: 'team_id', title: 'Team ID', description: 'task.team_id' },
    { key: 'team_name', title: 'Team Name', description: 'task.team_name' },
    { key: 'deal_id', title: 'Deal ID', description: 'task.deal_id' },
    { key: 'deal_title', title: 'Deal Title', description: 'task.deal_title' },
    { key: 'originating_conversation_id', title: 'Conversation ID', description: 'task.originating_conversation_id' }
  ].freeze
  APPOINTMENT_FIELD_DEFINITIONS = [
    { key: 'id', title: 'Appointment ID', description: 'appointment.id' },
    { key: 'resource_id', title: 'Specialist ID', description: 'appointment.resource_id' },
    { key: 'resource_name', title: 'Specialist Name', description: 'appointment.resource_name' },
    { key: 'contact_id', title: 'Contact ID', description: 'appointment.contact_id' },
    { key: 'service_id', title: 'Service ID', description: 'appointment.service_id' },
    { key: 'company_id', title: 'Company ID', description: 'appointment.company_id' },
    { key: 'conversation_id', title: 'Conversation ID', description: 'appointment.conversation_id' },
    { key: 'created_by_id', title: 'Created By User ID', description: 'appointment.created_by_id' },
    { key: 'starts_at', title: 'Start Timestamp', description: 'appointment.starts_at (full timestamp with timezone)' },
    { key: 'ends_at', title: 'End Timestamp', description: 'appointment.ends_at (full timestamp with timezone)' },
    { key: 'duration_min', title: 'Duration (minutes)', description: 'appointment.duration_min' },
    { key: 'start_date', title: 'Start Date (dd.mm.yyyy)', description: 'appointment.start_date (local calendar date of the appointment)' },
    { key: 'start_time', title: 'Start Time (HH:MM)', description: 'appointment.start_time (local time only, e.g. 14:30)' },
    { key: 'end_date', title: 'End Date (dd.mm.yyyy)', description: 'appointment.end_date (local calendar date of the appointment end)' },
    { key: 'end_time', title: 'End Time (HH:MM)', description: 'appointment.end_time (local time only, e.g. 15:00)' },
    { key: 'status', title: 'Status', description: 'appointment.status' },
    { key: 'appointment_type', title: 'Appointment Type', description: 'appointment.appointment_type' },
    { key: 'client_name', title: 'Client Name', description: 'appointment.client_name' },
    { key: 'client_phone', title: 'Client Phone', description: 'appointment.client_phone' },
    { key: 'client_identifier', title: 'Client Identifier', description: 'appointment.client_identifier' },
    { key: 'client_birth_date', title: 'Client Birth Date', description: 'appointment.client_birth_date' },
    { key: 'client_gender', title: 'Client Gender', description: 'appointment.client_gender' },
    { key: 'client_comment', title: 'Client Comment', description: 'appointment.client_comment' },
    { key: 'source', title: 'Source', description: 'appointment.source' },
    { key: 'external_ref', title: 'External Reference', description: 'appointment.external_ref' },
    { key: 'payment_status', title: 'Payment Status', description: 'appointment.payment_status' },
    { key: 'service_name_snapshot', title: 'Service Name', description: 'appointment.service_name_snapshot' },
    { key: 'service_type_snapshot', title: 'Service Type', description: 'appointment.service_type_snapshot' },
    { key: 'service_duration_min_snapshot', title: 'Service Duration (minutes)', description: 'appointment.service_duration_min_snapshot' },
    { key: 'service_amount', title: 'Service Amount', description: 'appointment.service_amount' },
    { key: 'compensation_type_snapshot', title: 'Compensation Type', description: 'appointment.compensation_type_snapshot' },
    { key: 'compensation_value_snapshot', title: 'Compensation Value', description: 'appointment.compensation_value_snapshot' },
    { key: 'compensation_percent_snapshot', title: 'Compensation Percent', description: 'appointment.compensation_percent_snapshot' },
    { key: 'prepaid_amount', title: 'Prepaid Amount', description: 'appointment.prepaid_amount' },
    { key: 'prepaid_payment_method', title: 'Prepaid Payment Method', description: 'appointment.prepaid_payment_method' },
    { key: 'settlement_amount', title: 'Settlement Amount', description: 'appointment.settlement_amount' },
    { key: 'settlement_payment_method', title: 'Settlement Payment Method', description: 'appointment.settlement_payment_method' }
  ].freeze

  ATTRIBUTE_MODELS = {
    'contact' => 'contact_attribute',
    'conversation' => 'conversation_attribute'
  }.freeze

  GROUP_NAMES = {
    'contact' => 'Contact',
    'contact_custom_attributes' => 'Contact Attributes',
    'conversation' => 'Conversation',
    'conversation_custom_attributes' => 'Conversation Attributes',
    'deal' => 'Deal',
    'deal_custom_attributes' => 'Deal Attributes',
    'task' => 'Task',
    'task_custom_attributes' => 'Task Attributes',
    'appointment' => 'Appointment',
    'appointment_custom_attributes' => 'Appointment Attributes'
  }.freeze

  class << self
    def definitions_for(account)
      contact_fields +
        conversation_fields +
        deal_fields(account) +
        task_fields(account) +
        appointment_fields(account) +
        custom_attribute_fields(account, 'contact') +
        custom_attribute_fields(account, 'conversation') +
        managed_custom_attribute_fields(account, 'deal') +
        managed_custom_attribute_fields(account, 'task') +
        appointment_custom_attribute_fields(account)
    end

    def definitions_for_user(account:, user:)
      filter_definitions_for_user(
        definitions_for(account),
        account: account,
        user: user
      )
    end

    def scope_visible_for_user?(scope:, account:, user:)
      return false unless scope_context_enabled?(scope, account)

      case scope.to_s
      when 'deal'
        user_has_any_permission?(
          account: account,
          user: user,
          permissions: %w[crm_deal_view crm_deal_manage]
        )
      when 'task'
        user_has_any_permission?(
          account: account,
          user: user,
          permissions: %w[crm_task_view crm_task_manage]
        )
      else
        true
      end
    end

    def field_ids_for(account)
      definitions_for(account).map { |field| field[:id] }
    end

    def appointment_state_for(account:, conversation: nil, appointment: nil)
      return if account.blank? || !appointment_context_enabled?(account)

      appointment ||= appointment_for(account: account, conversation: conversation)
      return if appointment.blank? || appointment.account_id != account.id

      build_appointment_state(appointment, account)
    end

    def deal_state_for(account:, conversation:)
      deal = deal_for(account: account, conversation: conversation)
      return if deal.blank?

      deal.attributes.symbolize_keys.slice(*DEAL_STATE_ATTRIBUTES).merge(
        amount: Crm::AmountFormatter.major_from_minor(deal.amount_minor),
        pipeline_name: deal.pipeline&.name,
        stage_name: deal.stage&.name,
        owner_name: deal.owner&.name,
        creator_name: deal.creator&.name,
        team_name: deal.team&.name,
        company_name: deal.company&.name
      ).slice(*DEAL_STATE_ATTRIBUTES)
    end

    def task_state_for(account:, conversation:)
      task = task_for(account: account, conversation: conversation)
      return if task.blank?

      task.attributes.symbolize_keys.slice(*TASK_STATE_ATTRIBUTES).merge(
        status_name: task.status&.name,
        assignee_name: task.assignee&.name,
        creator_name: task.creator&.name,
        team_name: task.team&.name,
        deal_title: task.deal&.title
      ).slice(*TASK_STATE_ATTRIBUTES)
    end

    def appointment_for(account:, conversation:)
      return if account.blank? || conversation.blank?
      return unless appointment_context_enabled?(account)

      appointments = account.scheduling_appointments.where(conversation_id: conversation.id)

      appointments.active_statuses.order(starts_at: :desc, id: :desc).first ||
        appointments.order(starts_at: :desc, id: :desc).first
    end

    def deal_for(account:, conversation:)
      return if account.blank? || conversation.blank?
      return unless deal_context_enabled?(account)

      deals = deals_for_conversation_context(account: account, conversation: conversation)

      deals.kept.where(closed_at: nil).order(updated_at: :desc, id: :desc).first ||
        deals.kept.order(updated_at: :desc, id: :desc).first ||
        deals.order(updated_at: :desc, id: :desc).first
    end

    def deals_for_conversation_context(account:, conversation:)
      deals = account.crm_deals.where(originating_conversation_id: conversation.id)
      thread = conversation.communication_thread || conversation.reload.communication_thread
      return deals if thread.blank? || thread.account_id != account.id

      deals.or(account.crm_deals.where(originating_communication_thread_id: thread.id))
    end

    def task_for(account:, conversation:)
      return if account.blank? || conversation.blank?
      return unless task_context_enabled?(account)

      tasks = account.crm_tasks.where(originating_conversation_id: conversation.id)

      tasks.kept.where(completed_at: nil).order(updated_at: :desc, id: :desc).first ||
        tasks.kept.order(updated_at: :desc, id: :desc).first ||
        tasks.order(updated_at: :desc, id: :desc).first
    end

    def runtime_state_for(account:, conversation:, channel_type: nil, assistant: nil, actor: nil, accessible_inboxes: nil)
      return {} if conversation.blank?

      runtime_state = {
        conversation: slice_record_attributes(conversation, CONVERSATION_STATE_ATTRIBUTES),
        contact: slice_record_attributes(conversation.contact, CONTACT_STATE_ATTRIBUTES),
        channel_type: channel_type
      }.compact

      communication_thread_state = communication_thread_state_for(
        account: account,
        conversation: conversation,
        assistant: assistant,
        actor: actor,
        accessible_inboxes: accessible_inboxes
      )
      runtime_state[:communication_thread] = communication_thread_state if communication_thread_state.present?

      deal_state = deal_state_for(account: account, conversation: conversation)
      runtime_state[:deal] = deal_state if deal_state.present?

      task_state = task_state_for(account: account, conversation: conversation)
      runtime_state[:task] = task_state if task_state.present?

      appointment_state = appointment_state_for(account: account, conversation: conversation)
      runtime_state[:appointment] = appointment_state if appointment_state.present?
      runtime_state
    end

    def communication_thread_state_for(account:, conversation:, assistant: nil, actor: nil, accessible_inboxes: nil)
      return if account.blank? || conversation.blank?
      return unless account.feature_enabled?('communication_threads')

      thread = conversation.communication_thread || conversation.reload.communication_thread
      return if thread.blank? || thread.account_id != account.id

      links = thread.communication_thread_conversations.includes(:conversation, :inbox, :contact_inbox).order(primary: :desc, created_at: :asc,
                                                                                                              id: :asc).to_a
      visible_links = visible_communication_thread_links(
        links,
        account: account,
        conversation: conversation,
        assistant: assistant,
        actor: actor,
        accessible_inboxes: accessible_inboxes
      )
      return if visible_links.blank?

      visible_inboxes = communication_thread_accessible_inboxes(
        account: account,
        assistant: assistant,
        actor: actor,
        accessible_inboxes: accessible_inboxes
      )
      channels = CommunicationThreads::ChannelCapabilitiesBuilder.new(
        links: visible_links,
        contact: thread.contact,
        available_inboxes: visible_inboxes || [],
        callable_inbox_ids: Array(visible_inboxes).map(&:id)
      ).perform.map do |channel|
        channel.slice(*COMMUNICATION_THREAD_CHANNEL_KEYS)
      end
      current_channel = channels.find { |channel| channel[:conversation_id] == conversation.display_id }

      {
        id: thread.id,
        display_id: thread.display_id,
        contact_id: thread.contact_id,
        status: thread.status,
        priority: thread.priority,
        unread_count: thread.unread_count,
        assignee_id: thread.assignee_id,
        team_id: thread.team_id,
        last_activity_at: thread.last_activity_at&.iso8601,
        conversation_ids: visible_links.map { |link| link.conversation.display_id },
        primary_conversation_id: visible_links.find(&:primary?)&.conversation&.display_id,
        current_conversation_id: conversation.display_id,
        current_channel_key: current_channel&.dig(:channel_key),
        current_channel: current_channel,
        channels: channels
      }.compact
    end

    def allowed_definitions_for(assistant)
      definitions = definitions_for(assistant.account)
      access = normalized_access_for(assistant, definitions)

      definitions.select do |field|
        scope = field[:table_name].to_sym
        access.dig(scope, :enabled) && access.dig(scope, :field_ids)&.include?(field[:id])
      end
    end

    def effective_definitions_for(assistant, field_ids: nil)
      definitions = definitions_for(assistant.account)
      explicit_field_ids = sanitize_field_ids(field_ids, definitions)

      definitions.select { |field| explicit_field_ids.include?(field[:id]) }
    end

    def allowed_field_ids_for(assistant)
      allowed_definitions_for(assistant).map { |field| field[:id] }
    end

    def normalized_access_for(assistant, definitions = definitions_for(assistant.account))
      available_ids_by_scope = definitions.group_by { |field| field[:table_name].to_sym }
                                          .transform_values { |fields| fields.map { |field| field[:id] } }
      raw_access = assistant.config&.with_indifferent_access&.dig(:context_access) || {}

      SCOPES.index_with do |scope|
        normalize_scope_access(scope, raw_access[scope], available_ids_by_scope[scope] || [])
      end
    end

    def prompt_state_for(assistant:, runtime_state:, field_ids: nil)
      definitions = definitions_for(assistant.account)
      explicit_field_ids = sanitize_field_ids(field_ids, definitions)
      prompt_state = {}
      visible_fields = {}
      custom_attribute_label_maps = custom_attribute_label_maps_for_definitions(
        effective_definitions_for(assistant, field_ids: explicit_field_ids)
      )

      SCOPES.each do |scope|
        effective_field_ids = always_visible_prompt_field_ids(definitions, scope) + explicit_field_ids.select do |field_id|
          field_id.start_with?("#{scope}.")
        end
        effective_field_ids = effective_field_ids.uniq
        next if effective_field_ids.blank?

        scoped_prompt_state = build_scoped_prompt_state(
          scope: scope,
          raw_scope_state: runtime_state[scope],
          allowed_field_ids: effective_field_ids
        )
        next if scoped_prompt_state.blank?

        prompt_state[scope] = scoped_prompt_state
        visible_fields[scope] = visible_core_field_keys(effective_field_ids, scope)
      end

      prompt_state[:visible_fields] = visible_fields if visible_fields.present?
      prompt_state[:communication_thread] = runtime_state[:communication_thread] if runtime_state[:communication_thread].present?
      custom_attribute_label_maps.each do |scope, labels|
        next if labels.blank?

        prompt_state[:"#{scope}_custom_attribute_labels"] = labels
      end
      prompt_state
    end

    def custom_attribute_label_maps_for_definitions(definitions)
      definitions
        .select { |field| field[:field_type] == 'custom_attribute' }
        .group_by { |field| field[:table_name].to_sym }
        .transform_values do |fields|
          fields.each_with_object({}) do |field, labels|
            labels[field[:field_key].to_s] = field[:title]
          end
        end
    end

    def glossary_groups_for_definitions(definitions)
      definitions
        .group_by { |field| field[:group_name] }
        .map do |group_name, fields|
          {
            group_name: group_name,
            entries: fields.map { |field| glossary_entry_for(field) }
          }
        end
    end

    def extract_field_ids_from_text(text)
      normalized_text =
        case text
        when String
          text
        when Array
          text.flatten.compact.map(&:to_s).join("\n")
        else
          text.to_s
        end

      return [] if normalized_text.blank?

      normalized_text.scan(FIELD_REFERENCE_REGEX).map { |_label, field_id| normalize_field_id(field_id) }.uniq
    end

    def render_references(text, prompt_state:, allowed_fields:)
      return text if text.blank?

      allowed_fields_by_id = allowed_fields.index_by { |field| field[:id] }

      text.gsub(FIELD_REFERENCE_REGEX) do
        label = Regexp.last_match(1)
        field_id = normalize_field_id(Regexp.last_match(2))
        definition = allowed_fields_by_id[field_id]
        cleaned_label = clean_reference_label(label, definition)

        next cleaned_label if definition.blank?

        value = value_for(prompt_state, field_id)
        formatted_value = format_value(value)

        formatted_value.present? ? "#{cleaned_label} (#{field_id}: #{formatted_value})" : "#{cleaned_label} (#{field_id})"
      end
    end

    def value_for_field_id(prompt_state, field_id)
      value_for(prompt_state, normalize_field_id(field_id))
    end

    def core_field_keys(scope)
      field_definitions_for(scope).map { |definition| definition[:key] }
    end

    private

    def build_appointment_state(appointment, account)
      timezone = ActiveSupport::TimeZone[appointment.resource&.timezone] ||
                 ActiveSupport::TimeZone[account.reporting_timezone] || Time.zone
      starts_at = appointment.starts_at&.in_time_zone(timezone)
      ends_at = appointment.ends_at&.in_time_zone(timezone)

      appointment.attributes.symbolize_keys.slice(*APPOINTMENT_STATE_ATTRIBUTES).merge(
        resource_name: appointment.resource&.name,
        start_date: starts_at&.strftime('%d.%m.%Y'),
        start_time: starts_at&.strftime('%H:%M'),
        end_date: ends_at&.strftime('%d.%m.%Y'),
        end_time: ends_at&.strftime('%H:%M')
      ).slice(*APPOINTMENT_STATE_ATTRIBUTES)
    end

    def visible_communication_thread_links(links, account:, conversation:, assistant:, actor:, accessible_inboxes:)
      inboxes = communication_thread_accessible_inboxes(
        account: account,
        assistant: assistant,
        actor: actor,
        accessible_inboxes: accessible_inboxes
      )

      if inboxes.present?
        visible_inbox_ids = inboxes.map(&:id)
        return links.select { |link| visible_inbox_ids.include?(link.inbox_id) }
      end

      return [] if communication_thread_access_scope_present?(assistant: assistant, actor: actor, accessible_inboxes: accessible_inboxes)

      links.select { |link| link.conversation_id == conversation.id }
    end

    def communication_thread_accessible_inboxes(account:, assistant:, actor:, accessible_inboxes:)
      return Array(accessible_inboxes) if accessible_inboxes

      return assistant.inboxes.where(account_id: account.id).includes(:channel).to_a if assistant.present?

      if actor.present? && actor.respond_to?(:id)
        account_user = AccountUser.find_by(account_id: account.id, user_id: actor.id)
        return account.inboxes.includes(:channel).to_a if account_user&.administrator?
        return actor.inboxes.where(account_id: account.id).includes(:channel).to_a if actor.respond_to?(:inboxes)

        return []
      end

      nil
    end

    def communication_thread_access_scope_present?(actor:, accessible_inboxes:, **)
      actor.present? || !accessible_inboxes.nil?
    end

    def sanitize_field_ids(field_ids, definitions)
      available_field_ids = definitions.map { |field| field[:id] }

      Array(field_ids).map { |field_id| normalize_field_id(field_id) }
                      .uniq
                      .select { |field_id| available_field_ids.include?(field_id) }
    end

    def slice_record_attributes(record, keys)
      return if record.blank?

      record.attributes.symbolize_keys.slice(*keys)
    end

    def always_visible_prompt_field_ids(definitions, scope)
      return [] unless %i[contact conversation].include?(scope.to_sym)

      definitions
        .select { |field| field[:table_name].to_sym == scope.to_sym }
        .map { |field| field[:id] }
    end

    def contact_fields
      build_field_group('contact', CONTACT_FIELD_DEFINITIONS)
    end

    def conversation_fields
      build_field_group('conversation', CONVERSATION_FIELD_DEFINITIONS)
    end

    def deal_fields(account)
      return [] unless deal_context_enabled?(account)

      build_field_group('deal', DEAL_FIELD_DEFINITIONS)
    end

    def task_fields(account)
      return [] unless task_context_enabled?(account)

      build_field_group('task', TASK_FIELD_DEFINITIONS)
    end

    def appointment_fields(account)
      return [] unless appointment_context_enabled?(account)

      build_field_group('appointment', APPOINTMENT_FIELD_DEFINITIONS)
    end

    def build_field_group(scope, definitions)
      definitions.map do |definition|
        {
          id: "#{scope}.#{definition[:key]}",
          title: definition[:title],
          description: definition[:description],
          group_name: GROUP_NAMES.fetch(scope),
          table_name: scope,
          field_type: 'field',
          field_key: definition[:key]
        }
      end
    end

    def custom_attribute_fields(account, scope)
      attribute_model = ATTRIBUTE_MODELS.fetch(scope)
      group_name = GROUP_NAMES.fetch("#{scope}_custom_attributes")

      account.custom_attribute_definitions
             .with_attribute_model(attribute_model)
             .map do |definition|
        {
          id: "#{scope}.custom_attributes.#{definition.attribute_key}",
          title: definition.attribute_display_name,
          description: "#{scope}.custom_attributes.#{definition.attribute_key}",
          group_name: group_name,
          table_name: scope,
          field_type: 'custom_attribute',
          field_key: definition.attribute_key
        }
      end
    end

    def appointment_custom_attribute_fields(account)
      return [] unless appointment_context_enabled?(account)

      managed_custom_attribute_fields(account, 'appointment')
    end

    def managed_custom_attribute_fields(account, scope)
      return [] unless scope_context_enabled?(scope, account)

      account.crm_field_definitions
             .active
             .for_entity_kind(scope)
             .ordered
             .map do |definition|
        {
          id: "#{scope}.custom_attributes.#{definition.key}",
          title: definition.label,
          description: "#{scope}.custom_attributes.#{definition.key}",
          group_name: GROUP_NAMES.fetch("#{scope}_custom_attributes"),
          table_name: scope,
          field_type: 'custom_attribute',
          field_key: definition.key,
          value_type: definition.field_type,
          required: definition.required,
          options: managed_custom_attribute_options(definition),
          default_value: definition.default_value,
          rules: definition.rules.presence,
          crm_managed: true
        }
      end
    end

    def managed_custom_attribute_options(definition)
      return [] unless %w[select multiselect].include?(definition.field_type)

      Array(definition.options).map do |option|
        normalized = option.is_a?(Hash) ? option.with_indifferent_access : { label: option, value: option }

        {
          label: normalized[:label].to_s,
          value: normalized[:value].to_s
        }
      end
    end

    def field_definitions_for(scope)
      case scope.to_s
      when 'contact'
        CONTACT_FIELD_DEFINITIONS
      when 'conversation'
        CONVERSATION_FIELD_DEFINITIONS
      when 'deal'
        DEAL_FIELD_DEFINITIONS
      when 'task'
        TASK_FIELD_DEFINITIONS
      when 'appointment'
        APPOINTMENT_FIELD_DEFINITIONS
      else
        []
      end
    end

    def normalize_scope_access(scope, raw_scope, available_field_ids)
      raw_scope = raw_scope.to_h.with_indifferent_access if raw_scope.respond_to?(:to_h)
      raw_scope ||= {}

      field_ids =
        if raw_scope.key?(:field_ids)
          Array(raw_scope[:field_ids]).map { |field_id| normalize_field_id(field_id) }
        else
          available_field_ids
        end

      {
        enabled: if raw_scope.key?(:enabled)
                   ActiveModel::Type::Boolean.new.cast(raw_scope[:enabled])
                 else
                   default_scope_enabled(scope,
                                         available_field_ids)
                 end,
        field_ids: field_ids & available_field_ids
      }
    end

    def default_scope_enabled(scope, available_field_ids)
      return false if available_field_ids.blank?

      %i[contact conversation].include?(scope.to_sym)
    end

    def deal_context_enabled?(account)
      account.feature_enabled?('crm_deals')
    end

    def task_context_enabled?(account)
      account.feature_enabled?('crm_tasks')
    end

    def appointment_context_enabled?(account)
      account.feature_enabled?('scheduling')
    end

    def scope_context_enabled?(scope, account)
      case scope.to_s
      when 'deal'
        deal_context_enabled?(account)
      when 'task'
        task_context_enabled?(account)
      when 'appointment'
        appointment_context_enabled?(account)
      else
        true
      end
    end

    def filter_definitions_for_user(definitions, account:, user:)
      definitions.select do |field|
        scope_visible_for_user?(
          scope: field[:table_name],
          account: account,
          user: user
        )
      end
    end

    def user_has_any_permission?(account:, user:, permissions:)
      return false if account.blank? || user.blank? || !user.respond_to?(:account_users)

      account_user = user.account_users.find_by(account_id: account.id)
      return false if account_user.blank?

      tokens = Array(account_user.permissions)
      tokens.include?('administrator') || permissions.any? { |token| tokens.include?(token) }
    end

    def build_scoped_prompt_state(scope:, raw_scope_state:, allowed_field_ids:)
      return {} if raw_scope_state.blank? || allowed_field_ids.blank?

      scope_state = raw_scope_state.with_indifferent_access
      prompt_state = {}

      allowed_field_ids.each do |field_id|
        _, *path = field_id.split('.')
        next if path.blank?

        case path.first
        when 'custom_attributes'
          add_selected_custom_attribute(prompt_state, scope_state, path.last)
        when 'additional_attributes'
          # Additional attributes remain available to tools in the raw runtime state,
          # but are intentionally excluded from the prompt-facing field whitelist.
          next
        else
          prompt_state[path.first] = scope_state[path.first]
        end
      end

      prompt_state
    end

    def add_selected_custom_attribute(prompt_state, scope_state, attribute_key)
      custom_attributes = scope_state[:custom_attributes]
      prompt_state[:custom_attributes] ||= {}

      if custom_attributes.is_a?(Hash)
        custom_attributes = custom_attributes.with_indifferent_access
        prompt_state[:custom_attributes][attribute_key] = custom_attributes[attribute_key]
      else
        prompt_state[:custom_attributes][attribute_key] = nil
      end
    end

    def visible_core_field_keys(allowed_field_ids, scope)
      allowed_field_ids
        .filter_map do |field_id|
          _, *path = field_id.split('.')
          next unless path.length == 1

          path.first
        end
        .uniq
        .select { |field_key| core_field_keys(scope).include?(field_key) }
    end

    def value_for(prompt_state, field_id)
      scope, *path = field_id.split('.')
      scoped_state = prompt_state&.with_indifferent_access&.dig(scope)
      return if scoped_state.blank?

      path.reduce(scoped_state.with_indifferent_access) do |memo, key|
        break unless memo.respond_to?(:with_indifferent_access)

        memo.with_indifferent_access[key]
      end
    end

    def format_value(value)
      case value
      when nil
        nil
      when Array
        value.map { |item| Captain::EncodingNormalizer.string(item.to_s) }.join(', ')
      when Hash
        JSON.generate(Captain::EncodingNormalizer.utf8(value))
      when String
        Captain::EncodingNormalizer.string(value).presence
      else
        value.to_s.presence
      end
    rescue JSON::GeneratorError
      Captain::EncodingNormalizer.string(value.to_s).presence
    end

    def clean_reference_label(label, definition)
      sanitized_label = label.to_s.sub(/\A\$\s*/, '').squish
      sanitized_label.presence || definition&.dig(:title) || 'Field'
    end

    def glossary_entry_for(field)
      field_id = field[:id].to_s
      description = field[:description].to_s
      normalized_description = description == field_id ? nil : description.presence

      {
        id: field_id,
        title: field[:title].to_s,
        description: normalized_description
      }
    end

    def normalize_field_id(field_id)
      field_id.to_s.gsub(/\\(.)/, '\1')
    end
  end
end
