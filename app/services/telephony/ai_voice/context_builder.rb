class Telephony::AiVoice::ContextBuilder
  DEFAULT_PROVIDER = 'gemini-live'.freeze
  DEFAULT_MODEL = 'gemini-3.1-flash-live-preview'.freeze
  DEFAULT_VOICE = 'sulafat'.freeze
  DEFAULT_LANGUAGE = 'ru-KZ'.freeze
  DEFAULT_FIRST_MESSAGE = 'Здравствуйте! Чем могу помочь?'.freeze
  DEFAULT_SYSTEM_PROMPT = <<~PROMPT.squish.freeze
    Ты голосовой ассистент в телефонном звонке.
    Говори по-русски, коротко и естественно.
    Не используй markdown, списки, эмодзи или спецсимволы.
    Отвечай максимум 1-2 короткими предложениями.
    Задавай только один вопрос за раз.
    Если пользователь перебивает, сразу остановись и слушай.
    Если не уверен, уточни коротким вопросом.
    Для действий с заказами, клиентами, переводом звонка или завершением звонка используй инструменты.
  PROMPT
  DEFAULT_MAX_DURATION_SEC = 900

  def initialize(params:)
    @params = params.deep_stringify_keys
  end

  def perform
    ensure_call_ref!
    session = call_session || create_call_session!

    {
      call_ref: session.external_call_ref,
      account_id: account.id,
      conversation_id: session.conversation_id,
      conversation_display_id: session.conversation&.display_id,
      contact_id: session.contact_id,
      inbox_id: session.inbox_id,
      number_ref: number_binding&.number_ref,
      caller_number: session.from_number || caller_number,
      ingress_number: session.to_number || ingress_number,
      ai: ai_payload,
      captain: captain_payload,
      transfer: transfer_payload,
      recording: recording_payload,
      tools: Telephony::AiVoice::ToolDispatchService.catalog(policy: routing_policy, captain_assistant: captain_assistant)
    }.compact
  end

  private

  attr_reader :params

  def ensure_call_ref!
    return if call_ref.present?

    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content)
  end

  def create_call_session!
    ensure_call_session_creation_scope!

    conversation = ensure_conversation
    account.telephony_call_sessions.create!(
      external_call_ref: call_ref,
      provider: 'fonoster',
      status: 'ringing',
      direction: 'inbound',
      from_number: caller_number,
      to_number: ingress_number,
      started_at: Time.current,
      conversation: conversation,
      contact: conversation&.contact || contact,
      inbox: inbox,
      number_binding: number_binding,
      metadata: { 'ai_voice' => { 'context_created' => true } }
    )
  rescue ActiveRecord::RecordNotUnique
    account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  rescue ActiveRecord::RecordInvalid => e
    raise unless uniqueness_conflict?(e.record, :external_call_ref)

    account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def ensure_conversation
    return call_session.conversation if call_session&.conversation.present?
    return unless inbox.present? && caller_number.present?

    Voice::InboundCallBuilder.perform!(
      account: account,
      inbox: inbox,
      from_number: caller_number,
      call_sid: call_ref
    )
  end

  def ensure_call_session_creation_scope!
    return if number_binding.present?

    raise Telephony::Error.new(
      code: 'CALL_SESSION_NOT_FOUND',
      message: 'call_ref was not found in the resolved account; number_ref or ingress_number is required to create a voice context',
      status: :not_found
    )
  end

  def ai_payload
    ai_settings.except('system_prompt', 'recording_enabled').merge(
      deployment_mode: routing_policy&.ai_deployment_mode || Telephony::RoutingPolicy::AI_DEPLOYMENT_FONOSTER_MANAGED,
      app_ref: routing_policy&.effective_ai_app_ref,
      system_prompt: system_prompt
    ).compact
  end

  def captain_payload
    return {} if captain_assistant.blank?

    {
      assistant_id: captain_assistant.id,
      name: captain_assistant.name,
      system_prompt: system_prompt,
      rules: captain_assistant.system_rule_contents,
      response_guidelines: captain_assistant.response_guidelines || [],
      guardrails: captain_assistant.guardrails || [],
      handoff_tool_name: captain_assistant.handoff_tool_name
    }
  end

  def transfer_payload
    operator_aor = routing_policy&.resolved_operator_agent_aor
    {
      enabled: operator_aor.present?,
      operator_agent_aor: operator_aor,
      message: ai_settings['transfer_message'].presence || 'Сейчас соединю вас со специалистом.'
    }.compact
  end

  def recording_payload
    {
      enabled: recording_enabled?,
      source: 'onelink_runtime',
      storage_provider: 'onelink_storage'
    }
  end

  def recording_enabled?
    return ActiveModel::Type::Boolean.new.cast(ai_settings['recording_enabled']) if ai_settings.key?('recording_enabled')

    true
  end

  def uniqueness_conflict?(record, attribute)
    record&.errors&.of_kind?(attribute, :taken)
  end

  def system_prompt
    base = []
    base << captain_assistant.system_instruction if captain_assistant&.system_instruction.present?
    base.concat(captain_assistant.system_rule_contents) if captain_assistant.present?
    base << ai_settings['system_prompt'] if ai_settings['system_prompt'].present?
    base << DEFAULT_SYSTEM_PROMPT
    base.compact_blank.join("\n")
  end

  def ai_settings
    @ai_settings ||= begin
      legacy_settings = (routing_policy&.ai_voice_settings || {}).deep_stringify_keys
      Telephony::AiVoice::VoiceSettingsDefaults.normalize(legacy_settings.merge(captain_voice_settings))
    end
  end

  def captain_voice_settings
    @captain_voice_settings ||= (captain_assistant&.config&.dig('voice_settings') || {}).deep_stringify_keys
  end

  def call_session
    @call_session ||= begin
      return if call_ref.blank?

      scoped_payload = params.merge('account_id' => account_id.presence || explicit_number_binding&.account_id)
      Telephony::AiVoice::CallSessionResolver.new(payload: scoped_payload).call_session
    end
  end

  def account
    @account ||= begin
      resolved = call_session&.account
      explicit = explicit_account
      raise_account_not_found! if account_id.present? && explicit.blank?
      raise_account_mismatch! if resolved.present? && explicit.present? && resolved.id != explicit.id

      resolved ||= explicit
      binding = explicit_number_binding
      raise_number_binding_mismatch! if resolved.present? && binding.present? && binding.account_id != resolved.id

      resolved ||= binding&.account
      resolved || raise(Telephony::Error.new(code: 'ACCOUNT_NOT_FOUND', message: 'Unable to resolve account for voice context', status: :not_found))
    end
  end

  def routing_policy
    @routing_policy ||= number_binding&.routing_policy || call_session&.number_binding&.routing_policy
  end

  def captain_assistant
    @captain_assistant ||= begin
      assistant = inbox_captain_assistant || routing_policy&.captain_assistant
      assistant if assistant&.account_id == account.id
    end
  end

  def inbox_captain_assistant
    return unless inbox.respond_to?(:captain_assistant)

    inbox.captain_assistant
  end

  def number_binding
    @number_binding ||= begin
      binding = explicit_number_binding || call_session&.number_binding
      raise_number_binding_mismatch! if binding.present? && account.present? && binding.account_id != account.id

      binding
    end
  end

  def explicit_number_binding
    @explicit_number_binding ||= begin
      scope = Telephony::NumberBinding.includes(:routing_policy, :account, :inbox)
      if number_ref.present?
        scope.find_by(number_ref: number_ref)
      elsif ingress_number.present?
        scope.find_by(phone_number: ingress_number)
      end
    end
  end

  def inbox
    @inbox ||= number_binding&.inbox || call_session&.inbox
  end

  def contact
    @contact ||= begin
      return call_session.contact if call_session&.contact.present?
      return if caller_number.blank? || account.blank?

      account.contacts.find_by(phone_number: caller_number) || account.contacts.find_by(phone_number: normalized_caller_number)
    end
  end

  def normalized_caller_number
    @normalized_caller_number ||= Contacts::PhoneNumberNormalizer.normalize(caller_number)
  end

  def call_ref
    params['call_ref'].presence || params['callRef'].presence || params['provider_call_id'].presence || params['providerCallId'].presence
  end

  def explicit_account
    @explicit_account ||= Account.find_by(id: account_id) if account_id.present?
  end

  def raise_account_mismatch!
    raise Telephony::Error.new(
      code: 'ACCOUNT_MISMATCH',
      message: 'call_ref does not belong to the requested account_id',
      status: :unprocessable_content
    )
  end

  def raise_account_not_found!
    raise Telephony::Error.new(
      code: 'ACCOUNT_NOT_FOUND',
      message: 'account_id does not resolve to an account',
      status: :not_found
    )
  end

  def raise_number_binding_mismatch!
    raise Telephony::Error.new(
      code: 'NUMBER_BINDING_ACCOUNT_MISMATCH',
      message: 'number_ref does not belong to the resolved account',
      status: :unprocessable_content
    )
  end

  def account_id
    params['account_id'].presence || params['accountId'].presence
  end

  def number_ref
    params['number_ref'].presence || params['numberRef'].presence
  end

  def caller_number
    params['caller_number'].presence || params['callerNumber'].presence || params['from_number'].presence || params['fromNumber'].presence ||
      params['from'].presence
  end

  def ingress_number
    params['ingress_number'].presence || params['ingressNumber'].presence || params['to_number'].presence || params['toNumber'].presence ||
      params['to'].presence
  end
end
