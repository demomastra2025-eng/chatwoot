# frozen_string_literal: true

# Execution-time boundary for customer-facing Captain tools. Catalog selection,
# prompt references, provider annotations and a model-supplied ID never grant access.
class Captain::CustomerToolExecutionScope
  class Denied < ArgumentError; end

  DENIED_MESSAGE = 'Tool is not authorized for customer AI execution scope'
  CUSTOMER_TASK_ACTIONS = %w[list create update cancel].freeze
  ALLOWED_TOOL_NAMES = %w[update_contact get_contact customer_tasks].freeze
  CONTACT_UPDATE_KEYS = %i[name email phone_number custom_attributes].freeze
  CONTACT_PROVIDER_OWNED_KEYS = %w[iin address phone_conflict_comment secondary_phones].freeze
  CUSTOMER_TASK_KEYS = %i[action task_id title task_type all_day due_at due_on request_reason idempotency_key].freeze

  class << self
    def allowed_tool_name?(name)
      ALLOWED_TOOL_NAMES.include?(name.to_s)
    end

    def ensure_allowed!(tool:, state:, params:, assistant: nil)
      action = trusted_action(tool)
      raise Denied, DENIED_MESSAGE if action.nil? || !state.is_a?(Hash) || !params.is_a?(Hash)

      state = state.with_indifferent_access
      assistant = verified_assistant!(state, assistant)
      conversation, contact = verified_contact!(state, assistant)

      validate_arguments!(action, params, assistant.account, conversation, contact)
      true
    end

    # The wrapper's preflight is not the execution boundary: a Contact merge can
    # rebind the conversation before the tool reads or writes it. Hold the same
    # account phone-identity lock used by merges, then the Contact and Conversation
    # rows until the actual tool operation finishes. Never follow a stale run to
    # the replacement Contact. The shared Thread owns Captain control; its
    # advisory and row locks must also span the effect, not just a preflight.
    def with_allowed_execution(tool:, state:, params:, assistant: nil, &)
      action = trusted_action(tool)
      raise Denied, DENIED_MESSAGE unless action && state.is_a?(Hash) && params.is_a?(Hash)
      raise Denied, DENIED_MESSAGE unless valid_contact_state?(state.with_indifferent_access)

      state = state.with_indifferent_access
      assistant = verified_assistant!(state, assistant)
      ::Contact.transaction do
        ::Contact.uncached do
          with_locked_contact!(action, state, params, assistant, &)
        end
      end
    end

    private

    def with_locked_contact!(action, state, params, assistant)
      Contacts::PhoneIdentityLock.acquire!(account_id: assistant.account_id)
      # Merge acquires the phone lock before the contact's Thread advisory.
      # A direct Contact owner callback already owns Contact before it claims
      # the Thread row; take Contact before Thread rows to avoid inversion.
      conversation_id = state.dig(:conversation, :id)
      contact_id = state.dig(:contact, :id)
      candidate = assistant.account.conversations.find_by(id: conversation_id)
      raise Denied, DENIED_MESSAGE unless candidate&.contact_id == contact_id.to_i

      Conversations::CommunicationThreadResolver.lock_contact_thread!(assistant.account_id, contact_id)
      contact = assistant.account.contacts.lock.find_by(id: state.dig(:contact, :id))
      raise Denied, DENIED_MESSAGE unless contact

      threads = CommunicationThread.where(account_id: assistant.account_id, contact_id: contact_id).order(:id).lock.to_a
      conversation = assistant.account.conversations.lock.find_by(id: conversation_id)
      raise Denied, DENIED_MESSAGE unless conversation&.contact_id == contact.id

      ensure_control_current!(conversation, threads, state, assistant)
      validate_arguments!(action, params, assistant.account, conversation, contact)
      yield
    end

    def ensure_control_current!(conversation, locked_threads, state, assistant)
      linked = conversation.communication_thread
      raise Denied, DENIED_MESSAGE if linked && locked_threads.none? { |thread| thread.id == linked.id }

      # Use a freshly locked owner rather than the preflight's cached
      # association. The unlinked Conversation row is already locked above.
      owner = linked ? locked_threads.find { |thread| thread.id == linked.id } : conversation
      expected = state[:captain_response_fence].to_h.with_indifferent_access[:control_generation]
      expected ||= state[:captain_control_generation]
      if owner.captain_control_state == Captain::Conversation::ControlService::HUMAN_CONTROL ||
         (expected.present? && owner.captain_control_generation.to_i != expected.to_i)
        raise Captain::Conversation::ControlGenerationStaleError, 'Captain control changed before tool execution'
      end

      # AccountToolAdapter does not inherit BasePublicTool's precheck. Perform
      # the full run validation under the same lock for reads and writes alike.
      return if state[:captain_response_fence].blank?

      Captain::Conversation::RunFenceService.new(assistant: assistant, state: state).ensure_current!
    end

    def verified_assistant!(state, assistant)
      assistant ||= Captain::Assistant.find_by(id: state[:assistant_id])
      raise Denied, DENIED_MESSAGE unless assistant.is_a?(Captain::Assistant) && assistant.persisted?
      raise Denied, DENIED_MESSAGE unless state[:assistant_id].to_s == assistant.id.to_s &&
                                          state[:account_id].to_s == assistant.account_id.to_s

      assistant
    end

    def verified_contact!(state, assistant)
      raise Denied, DENIED_MESSAGE unless valid_contact_state?(state)

      conversation = assistant.account.conversations.find_by(id: state.dig(:conversation, :id))
      contact = assistant.account.contacts.find_by(id: conversation&.contact_id)
      raise Denied, DENIED_MESSAGE if conversation.blank? || contact.blank?
      raise Denied, DENIED_MESSAGE unless valid_id?(state.dig(:contact, :id), contact.id)

      [conversation, contact]
    end

    def valid_contact_state?(state)
      state[:conversation].is_a?(Hash) && state[:contact].is_a?(Hash) && positive_id?(state.dig(:contact, :id))
    end

    def trusted_action(tool)
      tool_name = tool.name.to_s
      allowed_classes = {
        'update_contact' => Captain::Tools::UpdateContactTool,
        'customer_tasks' => Captain::Tools::CustomerTasksTool,
        'get_contact' => Captain::Tools::Agent::AccountToolAdapter
      }
      return unless allowed_classes[tool_name] == tool.class
      return if tool_name == 'get_contact' &&
                Captain::ToolRegistry.definition_for('get_contact')&.assistant_tool_class != Captain::Tools::Account::GetContactService

      tool_name
    end

    def validate_arguments!(action, params, account, conversation, contact)
      params = params.deep_symbolize_keys
      case action
      when 'update_contact'
        validate_contact_update!(params)
      when 'get_contact'
        raise Denied, DENIED_MESSAGE unless params.keys == [:contact_id] && valid_id?(params[:contact_id], contact.id)
      when 'customer_tasks'
        validate_customer_task!(params, account, conversation, contact)
      end
    end

    def validate_contact_update!(params)
      raise Denied, DENIED_MESSAGE unless (params.keys - CONTACT_UPDATE_KEYS).empty?
      return unless params.key?(:custom_attributes)

      attributes = parsed_contact_custom_attributes!(params[:custom_attributes])
      raise Denied, DENIED_MESSAGE if attributes.keys.any? { |key| provider_owned_contact_key?(key) }
    end

    def parsed_contact_custom_attributes!(value)
      attributes = value.is_a?(String) ? JSON.parse(value) : value
      raise Denied, DENIED_MESSAGE unless attributes.is_a?(Hash)
      raise Denied, DENIED_MESSAGE unless attributes.keys.all? { |key| key.is_a?(String) || key.is_a?(Symbol) }

      attributes
    rescue JSON::ParserError
      raise Denied, DENIED_MESSAGE
    end

    def provider_owned_contact_key?(key)
      name = key.to_s.strip.downcase
      name.start_with?('medelement_') || CONTACT_PROVIDER_OWNED_KEYS.include?(name)
    end

    def validate_customer_task!(params, account, conversation, contact)
      raise Denied, DENIED_MESSAGE unless (params.keys - CUSTOMER_TASK_KEYS).empty?
      raise Denied, DENIED_MESSAGE unless CUSTOMER_TASK_ACTIONS.include?(params[:action].to_s)

      thread = conversation.communication_thread
      raise Denied, DENIED_MESSAGE unless thread&.account_id == account.id && thread.contact_id == contact.id

      validate_customer_task_target!(params, account, contact, thread)
    end

    def validate_customer_task_target!(params, account, contact, thread)
      unless %w[update cancel].include?(params[:action].to_s)
        raise Denied, DENIED_MESSAGE if params[:task_id].present?

        return
      end

      task_id = params[:task_id]
      raise Denied, DENIED_MESSAGE unless positive_id?(task_id)

      scope = Crm::Tasks::CustomerScope.resolve(account: account, contact: contact, communication_thread: thread)
      raise Denied, DENIED_MESSAGE unless scope.exists?(id: task_id.to_i)
    end

    def valid_id?(value, expected)
      positive_id?(value) && value.to_i == expected
    end

    def positive_id?(value)
      (value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A[1-9]\d*\z/))) && value.to_i.positive?
    end
  end
end
