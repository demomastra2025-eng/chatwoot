class Api::V1::Accounts::BulkActionsController < Api::V1::Accounts::BaseController
  SERVER_SELECTION_KEYS = %w[mode excluded_ids filters payload].freeze
  SERVER_SELECTION_FILTER_KEYS = %w[
    inbox_id assignee_type status sort_by page labels team_id conversation_type
    communication_thread_mode crm_pipeline_id crm_stage_id appointment_status
    labels_scope team_scope unread
  ].freeze
  SERVER_SELECTION_REQUIRED_FILTER_KEYS = %w[assignee_type status].freeze
  SERVER_SELECTION_ASSIGNEE_TYPES = %w[all me unassigned assigned].freeze
  SERVER_SELECTION_CONVERSATION_TYPES = %w[mention participating unattended].freeze
  SERVER_SELECTION_QUERY_OPERATORS = %w[and or].freeze
  CUSTOM_ATTRIBUTE_OPERATORS = {
    'list' => %w[equal_to not_equal_to],
    'link' => %w[equal_to not_equal_to],
    'checkbox' => %w[equal_to not_equal_to],
    'text' => %w[equal_to not_equal_to contains does_not_contain],
    'number' => %w[equal_to not_equal_to is_present is_not_present is_greater_than is_less_than],
    'currency' => %w[equal_to not_equal_to is_present is_not_present is_greater_than is_less_than],
    'percent' => %w[equal_to not_equal_to is_present is_not_present is_greater_than is_less_than],
    'date' => %w[equal_to not_equal_to is_present is_not_present is_greater_than is_less_than]
  }.freeze
  SERVER_SELECTION_PAYLOAD_KEYS = %w[
    attribute_key filter_operator query_operator attribute_model custom_attribute_type values
  ].freeze

  def create
    case normalized_type
    when 'Conversation', 'CommunicationThread'
      ensure_communication_threads_feature_enabled! if normalized_type == 'CommunicationThread'
      return if performed?
      return unless valid_conversation_selection?

      bulk_action_run = create_conversation_bulk_action_run!
      enqueue_conversation_job(bulk_action_run)
      render json: { payload: bulk_action_run.as_progress_json }, status: :ok
    when 'Contact'
      check_authorization_for_contact_action
      enqueue_contact_job
      head :ok
    else
      render json: { success: false }, status: :unprocessable_content
    end
  end

  private

  def normalized_type
    params[:type].to_s.camelize
  end

  def valid_conversation_selection?
    selection = params[:selection]
    valid = if selection.present?
              valid_server_selection?(selection)
            else
              Array(params[:ids]).compact_blank.present?
            end
    return true if valid

    render json: { error: 'A non-empty ids list or supported server selection is required' },
           status: :unprocessable_content
    false
  end

  def valid_server_selection?(selection)
    return false unless normalized_type == 'CommunicationThread' && selection[:mode] == 'all_matching'
    return false unless (selection.keys.map(&:to_s) - SERVER_SELECTION_KEYS).empty?

    filters = selection[:filters]
    return false unless filters.respond_to?(:keys)

    filter_keys = filters.keys.map(&:to_s)
    return false unless (filter_keys - SERVER_SELECTION_FILTER_KEYS).empty?
    return false unless (SERVER_SELECTION_REQUIRED_FILTER_KEYS - filter_keys).empty?
    return false unless valid_server_selection_filter_values?(filters)
    return false unless valid_server_selection_payload?(selection[:payload])
    return false unless resolvable_server_selection_scope?(filters, selection[:payload])

    excluded_ids = selection[:excluded_ids]
    return false unless excluded_ids.nil? || excluded_ids.is_a?(Array)

    Array(excluded_ids).compact_blank.all? { |id| positive_integer?(id) }
  end

  def valid_server_selection_filter_values?(filters)
    status = filters[:status].to_s
    assignee_type = filters[:assignee_type].to_s
    sort_by = filters[:sort_by]

    return false unless status == 'all' || CommunicationThread.statuses.key?(status)
    return false unless SERVER_SELECTION_ASSIGNEE_TYPES.include?(assignee_type)
    return false unless sort_by.nil? || (sort_by.is_a?(String) && CommunicationThreadFinder::SORT_OPTIONS.key?(sort_by))
    return false unless valid_optional_positive_integer?(filters[:page])
    return false unless valid_optional_positive_integer?(filters[:inbox_id])
    return false unless valid_optional_positive_integer?(filters[:team_id])
    return false unless valid_optional_positive_integer?(filters[:crm_pipeline_id])
    return false unless valid_optional_positive_integer?(filters[:crm_stage_id])
    return false unless valid_labels_filter?(filters[:labels])
    return false unless valid_conversation_type_filter?(filters[:conversation_type])
    communication_thread_mode = filters[:communication_thread_mode]
    return false unless communication_thread_mode.nil? || communication_thread_mode == true
    return false unless valid_scope_filter?(filters[:labels_scope])
    return false unless valid_scope_filter?(filters[:team_scope])
    return false unless valid_boolean_filter?(filters[:unread])

    appointment_status = filters[:appointment_status]
    appointment_status.nil? ||
      (appointment_status.is_a?(String) && Scheduling::Constants::APPOINTMENT_STATUSES.include?(appointment_status))
  end

  def valid_server_selection_payload?(payload)
    return true if payload.nil?
    return false unless payload.is_a?(Array)

    payload.each_with_index.all? do |condition, index|
      next false unless condition.respond_to?(:keys)

      keys = condition.keys.map(&:to_s)
      (keys - SERVER_SELECTION_PAYLOAD_KEYS).empty? &&
        condition[:attribute_key].present? &&
        condition[:filter_operator].present? &&
        condition[:values].is_a?(Array) &&
        valid_payload_query_operator?(condition[:query_operator], last: index == payload.length - 1) &&
        valid_payload_enum_values?(condition) &&
        valid_custom_attribute_operator?(condition)
    end
  end

  def resolvable_server_selection_scope?(filters, payload)
    scope_params = filters.to_unsafe_h.with_indifferent_access
    if payload.present?
      CommunicationThreads::FilterService.new(
        scope_params.merge(payload: payload),
        current_user,
        @current_account,
        operational: true
      ).perform_scope.limit(1).load
    else
      CommunicationThreadFinder.new(current_user, scope_params, operational: true).perform_scope.limit(1).load
    end
    true
  rescue CommunicationThreadFinder::InvalidParameter,
         CustomExceptions::Base,
         ActiveRecord::StatementInvalid,
         ArgumentError,
         KeyError
    false
  end

  def positive_integer?(value)
    Integer(value, exception: false)&.positive?
  end

  def valid_optional_positive_integer?(value)
    value.nil? || positive_integer?(value)
  end

  def valid_labels_filter?(labels)
    labels.nil? || (labels.is_a?(Array) && labels.all? { |label| label.is_a?(String) && label.present? })
  end

  def valid_conversation_type_filter?(conversation_type)
    conversation_type.nil? ||
      (conversation_type.is_a?(String) && SERVER_SELECTION_CONVERSATION_TYPES.include?(conversation_type))
  end

  def valid_scope_filter?(value)
    value.nil? || value == 'any'
  end

  def valid_boolean_filter?(value)
    value.nil? || value == true || value == false
  end

  def valid_payload_query_operator?(operator, last:)
    return operator.blank? if last

    SERVER_SELECTION_QUERY_OPERATORS.include?(operator.to_s.downcase)
  end

  def valid_payload_enum_values?(condition)
    values = condition[:values]
    return true if %w[is_present is_not_present].include?(condition[:filter_operator])
    return false if values.blank?

    case condition[:attribute_key]
    when 'status'
      values.all? { |value| value == 'all' || Conversation.statuses.key?(value.to_s) }
    when 'priority'
      values.all? { |value| Conversation.priorities.key?(value.to_s) }
    when 'message_type'
      values.all? { |value| Message.message_types.key?(value.to_s) }
    else
      true
    end
  end

  def valid_custom_attribute_operator?(condition)
    declared_models = [condition[:custom_attribute_type], condition[:attribute_model]].compact_blank.uniq
    return false unless declared_models.empty? || declared_models == ['conversation_attribute']

    definition = @current_account.custom_attribute_definitions.find_by(
      attribute_key: condition[:attribute_key],
      attribute_model: 'conversation_attribute'
    )
    return true unless definition

    CUSTOM_ATTRIBUTE_OPERATORS.fetch(definition.attribute_display_type).include?(condition[:filter_operator])
  end

  def enqueue_conversation_job(bulk_action_run)
    ::BulkActionsJob.perform_later(
      account: @current_account,
      user: current_user,
      params: conversation_params,
      bulk_action_run_id: bulk_action_run.id
    )
  end

  def enqueue_contact_job
    Contacts::BulkActionJob.perform_later(
      @current_account.id,
      current_user.id,
      contact_params
    )
  end

  def delete_contact_action?
    params[:action_name] == 'delete'
  end

  def check_authorization_for_contact_action
    authorize(Contact, :destroy?) if delete_contact_action?
  end

  def conversation_params
    # TODO: Align conversation payloads with the `{ action_name, action_attributes }`
    # and then remove this method in favor of a common params method.
    base = params.permit(:snoozed_until)
    base[:fields] = conversation_fields if conversation_fields.present?
    append_common_bulk_attributes(base)
  end

  def contact_params
    # TODO: remove this method in favor of a common params method.
    # once legacy conversation payloads are migrated.
    append_common_bulk_attributes({})
  end

  def append_common_bulk_attributes(base_params)
    # NOTE: Conversation payloads historically diverged per action. Going forward we
    # want all objects to share a common contract: `{ action_name, action_attributes }`
    common = params.permit(
      :type,
      :action_name,
      ids: [],
      labels: [add: [], remove: []],
      selection: [
        :mode,
        { excluded_ids: [] },
        { filters: {} },
        {
          payload: [
            :attribute_key,
            :filter_operator,
            :query_operator,
            :attribute_model,
            :custom_attribute_type,
            { values: [] }
          ]
        }
      ]
    )
    base_params.merge(common)
  end

  def create_conversation_bulk_action_run!
    @current_account.bulk_action_runs.create!(
      user: current_user,
      resource_type: normalized_type,
      action_name: conversation_action_name,
      metadata: {
        selected_count: Array(params[:ids]).size,
        selection_mode: params.dig(:selection, :mode).presence || 'explicit'
      }
    )
  end

  def conversation_action_name
    return params[:action_name].to_s if params[:action_name].present?
    return 'remove_labels' if params.dig(:labels, :remove).present?
    return 'add_labels' if params.dig(:labels, :add).present?

    fields = conversation_fields
    return 'update' if fields.keys.size > 1
    return 'update_status' if fields.key?(:status) || fields.key?('status')
    return 'assign_agent' if fields.key?(:assignee_id) || fields.key?('assignee_id')
    return 'assign_team' if fields.key?(:team_id) || fields.key?('team_id')

    'update'
  end

  def conversation_fields
    @conversation_fields ||= params.fetch(:fields, ActionController::Parameters.new)
                                   .permit(:status, :assignee_id, :team_id)
                                   .to_h
  end

  def ensure_communication_threads_feature_enabled!
    return if Current.account&.feature_enabled?('communication_threads')

    render json: { error: 'Communication threads feature is disabled' }, status: :forbidden
  end
end
