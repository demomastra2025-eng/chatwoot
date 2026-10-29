# frozen_string_literal: true

# The Playground of the AI: the whole AI of the workspace is tried out, as a text channel is, or the AI of one channel when the user
# picks it (a voice channel gives the agent of that number alone). It has no start agent: the router picks the agent that answers each
# message among the enabled agents, and the model controls apply to whichever agent answers.
class Api::V1::Accounts::Captain::PlaygroundController < Api::V1::Accounts::BaseController
  ACTIONS = %w[message session reset permissions confirm].freeze

  wrap_parameters false
  before_action :current_account
  before_action -> { authorize(Captain::Assistant, :playground?) }

  def create
    test_overrides, invalid_override = Captain::Playground::TestOverrides.new(playground_params, account: Current.account).resolve
    return render json: { error: 'unsupported_playground_setting', field: invalid_override }, status: :unprocessable_entity if invalid_override

    render json: playground_response(test_overrides)
  rescue Captain::Playground::SessionStore::Busy, Captain::Playground::SessionStore::Stale => e
    render json: { error: 'playground_session_conflict', message: e.message }, status: :conflict
  rescue Pundit::NotAuthorizedError
    render json: { error: 'playground_live_forbidden' }, status: :forbidden
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: 'invalid_playground_scenario', message: e.message }, status: :unprocessable_entity
  rescue Rack::Timeout::RequestTimeoutException, Rack::Timeout::RequestTimeoutError, Timeout::Error => e
    render_timeout_response(e)
  end

  private

  def render_timeout_response(error)
    Rails.logger.warn("#{self.class.name} playground timed out for account #{Current.account.id}: #{error.class} - #{error.message}")
    render json: {
      response: nil,
      timed_out: true,
      status: 'timed_out',
      response_mode: 'human',
      human_needed: true,
      error_class: error.class.name,
      operator_note: 'Request timed out; human follow-up required.'
    }
  end

  def playground_params
    params.permit(
      :message_content,
      :conversation_id,
      :test_model,
      :test_temperature,
      :test_thinking_effort,
      :playground_mode,
      :playground_session_id,
      :playground_action,
      :restore_session,
      :real_data_read, :real_data_write, :approval_id, :approval_digest,
      :inbox_id,
      :live_inbox_id,
      :external_delivery_enabled,
      :controlled_test_number,
      scenario: {}
    )
  end

  def playground_action
    action = playground_params[:playground_action].presence || 'message'
    raise ArgumentError, 'Invalid Playground action' unless ACTIONS.include?(action)

    action
  end

  def playground_response(test_overrides)
    attributes = playground_params
    action = playground_action
    raise ArgumentError, 'The Playground caller always stays synthetic' if attributes[:conversation_id].present?
    raise ArgumentError, 'External delivery is unavailable in Playground' if delivery_requested?

    session = playground_session(action, attributes)
    return permissions_response(session, attributes) if action == 'permissions'

    session.with_lock(**lock_options(action, attributes)) do
      next confirm_response(session, attributes) if action == 'confirm'
      next { playground: session.payload } unless action == 'message'

      message_response(session, attributes[:message_content], test_overrides)
    end
  end

  def lock_options(action, attributes)
    {
      reset: action == 'reset', scenario_input: attributes[:scenario]&.to_h,
      inbox_id: attributes[:inbox_id].presence || attributes[:live_inbox_id], delivery_enabled: attributes[:external_delivery_enabled],
      delivery_target: attributes[:controlled_test_number]
    }
  end

  def delivery_requested?
    ActiveModel::Type::Boolean.new.cast(playground_params[:external_delivery_enabled])
  end

  def playground_session(action, attributes)
    isolated = attributes[:playground_session_id].blank? && action != 'reset' &&
               !ActiveModel::Type::Boolean.new.cast(attributes[:restore_session])
    Captain::Playground::Session.new(
      account: Current.account, user: Current.user, mode: attributes[:playground_mode].presence || 'workspace',
      session_id: attributes[:playground_session_id], isolated: isolated
    )
  end

  def permissions_response(session, attributes)
    raise ArgumentError, 'A Playground session is required' if attributes[:playground_session_id].blank?

    permissions = session.set_permissions!(read: attributes[:real_data_read], write: attributes[:real_data_write])
    { playground: { session_id: attributes[:playground_session_id], mode: 'workspace',
                    real_data_read: permissions['read'], real_data_write: permissions['write'], action_previews: [] } }
  end

  def confirm_response(session, attributes)
    result = Captain::Playground::ActionApproval.new(session).confirm(id: attributes[:approval_id], digest: attributes[:approval_digest])
    result.merge(playground: session.payload)
  end

  def message_response(session, message_content, test_overrides)
    options = { scope: session.scope, source: 'playground', playground_session: session }
    options[:test_overrides] = test_overrides if test_overrides.present?
    history = session.history_with(message_content)
    response = Captain::Assistant::AgentRunnerService.new(**options).generate_response(message_history: history)
    session.record_turn(message_content, response)
    enrich_handoff_status(response).merge(
      'playground' => session.payload,
      'delivery' => Captain::Playground::ReplyDelivery.new(session).perform(response)
    )
  end

  def enrich_handoff_status(response)
    return response unless response.is_a?(Hash)

    indifferent = response.with_indifferent_access
    handoff_triggered = ActiveModel::Type::Boolean.new.cast(indifferent[:handoff_tool_called]) ||
                        ActiveModel::Type::Boolean.new.cast(indifferent[:routing_handoff]) ||
                        ['conversation_handoff', Captain::Assistant::AgentRunnerService::PROVIDER_ERROR_RESPONSE].include?(
                          indifferent[:response].to_s
                        )
    return response unless handoff_triggered

    response.merge('human_needed' => true, 'status' => 'handoff_required')
  end
end
