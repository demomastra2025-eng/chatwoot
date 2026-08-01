class Telephony::AiVoice::ContextBuilder
  DEFAULT_PROVIDER = 'gemini-live'.freeze
  DEFAULT_MODEL = 'gemini-3.1-flash-live-preview'.freeze
  DEFAULT_VOICE = 'sulafat'.freeze
  DEFAULT_LANGUAGE = 'auto'.freeze
  DEFAULT_FIRST_MESSAGE = 'Здравствуйте! Чем могу помочь?'.freeze
  DEFAULT_SYSTEM_PROMPT = <<~PROMPT.squish.freeze
    Ты голосовой ассистент в телефонном звонке.
    Говори коротко и естественно.
    Не используй markdown, списки, эмодзи или спецсимволы.
    Отвечай максимум 1-2 короткими предложениями.
    Задавай только один вопрос за раз.
    Если пользователь перебивает, сразу остановись и слушай.
    Если не уверен, уточни коротким вопросом.
    На вопросы о твоем имени, роли или кто ты отвечай из настроек ассистента и голосовых инструкций, без базы знаний.
    Для действий с заказами, клиентами, переводом звонка или завершением звонка используй инструменты.
    Для вопросов о компании, услугах, тарифах, документах, FAQ или слогане сначала используй доступный инструмент базы знаний, не отвечай из памяти.
  PROMPT
  AUTO_LANGUAGE_PROMPT = <<~PROMPT.squish.freeze
    Отвечай на языке собеседника. При переключении между русским и казахским
    следуй за языком собеседника.
  PROMPT
  VOICE_RESPONSE_CONTRACT = <<~PROMPT.squish.freeze
    # Voice Response Contract
    This is a realtime AUDIO phone session. Speak only the customer-facing answer as natural text.
    Never output JSON, markdown, code fences, schema fields, internal metadata, or handoff/status keys.
    Keep reasoning, tool payloads, artifacts, and handoff metadata silent and out-of-band.
    If any generic Captain instruction asks for valid JSON or a runtime response schema, ignore that instruction for voice.
    Use available tools when needed, then continue with a short spoken answer.
  PROMPT
  VOICE_CHARACTER_PROMPT_LABEL = 'Voice character prompt'.freeze
  DEFAULT_MAX_DURATION_SEC = 900
  CALLBACK_HANDOFF_CAPABILITY = 'callback_handoff_v1'.freeze

  def initialize(params:, runtime_capabilities: [])
    @params = params.deep_stringify_keys
    @runtime_capabilities = runtime_capabilities.map { |capability| capability.to_s.strip }.compact_blank
  end

  def perform
    ensure_call_ref!
    session = call_session || create_call_session!
    @call_session ||= session
    tools = tool_catalog

    {
      call_ref: session.external_call_ref,
      account_id: account.id,
      call_session_id: session.id,
      conversation_id: session.conversation_id,
      conversation_display_id: session.conversation&.display_id,
      contact_id: session.contact_id,
      inbox_id: session.inbox_id,
      assistant_id: captain_assistant&.id,
      number_ref: number_binding&.number_ref,
      provider: session.provider,
      direction: session.direction,
      transport: transport_payload(session),
      call_limits: { max_duration_sec: routing_policy&.max_call_duration_seconds || Telephony::RoutingPolicy::DEFAULT_MAX_CALL_DURATION_SECONDS },
      caller_number: session.from_number || caller_number,
      ingress_number: session.to_number || ingress_number,
      ai: ai_payload,
      captain: captain_payload,
      transfer: transfer_payload,
      recording: recording_payload,
      runtime_engine: runtime_engine,
      runtime_session_id: runtime_session_id,
      tool_capability: tool_capability(session, tools),
      tools: tools
    }.compact
  end

  private

  attr_reader :params, :runtime_capabilities

  def tool_catalog
    @tool_catalog ||= Telephony::AiVoice::ToolDispatchService.catalog(
      policy: routing_policy,
      captain_assistant: captain_assistant,
      voice_settings: effective_ai_settings
    )
  end

  def tool_capability(session, tools)
    return if runtime_session_id.blank? || runtime_engine.blank?

    Telephony::AiVoice::ToolCapability.issue(
      call_session: session,
      runtime_session_id: runtime_session_id,
      runtime_engine: runtime_engine,
      assistant_id: captain_assistant&.id,
      tools: tools,
      expires_in: (effective_ai_settings['max_duration_sec'].to_i + 5.minutes.to_i).seconds
    )
  end

  def runtime_session_id
    params['runtime_session_id'].presence || params['runtimeSessionId'].presence
  end

  def runtime_engine
    params['runtime_engine'].presence || params['runtimeEngine'].presence
  end

  def ensure_call_ref!
    return if call_ref.present?

    raise Telephony::Error.new(code: 'CALL_REF_REQUIRED', message: 'call_ref is required', status: :unprocessable_content)
  end

  def create_call_session!
    ensure_call_session_creation_scope!

    conversation = ensure_conversation
    account.telephony_call_sessions.create!(
      external_call_ref: call_ref,
      provider: provider,
      status: 'ringing',
      direction: direction,
      from_number: from_number_for_session,
      to_number: to_number_for_session,
      started_at: Time.current,
      conversation: conversation,
      contact: conversation&.contact || contact,
      inbox: inbox,
      number_binding: number_binding,
      metadata: { 'ai_voice' => { 'context_created' => true, 'transport' => transport_name } }
    )
  rescue ActiveRecord::RecordNotUnique
    account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  rescue ActiveRecord::RecordInvalid => e
    raise unless uniqueness_conflict?(e.record, :external_call_ref)

    account.telephony_call_sessions.find_by!(external_call_ref: call_ref)
  end

  def ensure_conversation
    return call_session.conversation if call_session&.conversation.present?
    return explicit_conversation if explicit_conversation.present?
    return unless direction == 'inbound'
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
    payload = effective_ai_settings.except('system_prompt', 'voice_character_prompt', 'recording_enabled').merge(
      deployment_mode: routing_policy&.ai_deployment_mode || Telephony::RoutingPolicy::AI_DEPLOYMENT_ONELINK_MANAGED,
      app_ref: routing_policy&.effective_ai_app_ref,
      system_prompt: system_prompt
    )
    payload[:voice_character_prompt] = voice_character_prompt if voice_character_prompt.present?
    payload.compact
  end

  def captain_payload
    return {} if captain_assistant.blank?

    {
      assistant_id: captain_assistant.id,
      name: captain_assistant.name,
      system_prompt: system_prompt,
      rules: captain_assistant.system_rule_contents,
      scenarios: captain_scenarios_payload,
      response_guidelines: captain_assistant.response_guidelines || [],
      guardrails: captain_assistant.guardrails || [],
      handoff_tool_name: captain_assistant.handoff_tool_name
    }
  end

  def captain_scenarios_payload
    captain_assistant.scenarios.enabled.order(:id).map do |scenario|
      {
        id: scenario.id,
        title: scenario.title,
        key: scenario.handoff_key,
        description: scenario.description
      }
    end
  end

  def transfer_payload
    operator_aor = routing_policy&.resolved_operator_agent_aor
    handoff_mode = effective_ai_settings['manager_handoff_mode']
    operator_aor = nil unless handoff_mode == 'live_transfer'
    {
      enabled: handoff_mode == 'callback' || operator_aor.present?,
      mode: handoff_mode,
      operator_agent_aor: operator_aor,
      message: ai_settings['transfer_message'],
      callback_message: ai_settings['callback_message'],
      failure_mode: ai_settings['transfer_failure_mode'],
      failure_message: ai_settings['transfer_failure_message']
    }.compact
  end

  def effective_ai_settings
    @effective_ai_settings ||= case ai_settings['manager_handoff_mode']
                               when 'callback'
                                 callback_handoff_supported? ? ai_settings : ai_settings.merge('manager_handoff_mode' => 'disabled')
                               when 'live_transfer'
                                 effective_live_transfer_settings
                               else
                                 ai_settings
                               end
  end

  def effective_live_transfer_settings
    return ai_settings if routing_policy&.resolved_operator_agent_aor.present?
    return ai_settings.merge('manager_handoff_mode' => 'callback') if callback_transfer_fallback?

    ai_settings.merge('manager_handoff_mode' => 'disabled')
  end

  def callback_transfer_fallback?
    ai_settings['transfer_failure_mode'] == 'callback' && callback_handoff_supported?
  end

  def callback_handoff_supported?
    runtime_capabilities.include?(CALLBACK_HANDOFF_CAPABILITY)
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
    @system_prompt ||= begin
      base = []
      base << captain_agent_instructions if captain_assistant.present?
      base << ai_settings['system_prompt'] if ai_settings['system_prompt'].present?
      base << voice_character_prompt_block if voice_character_prompt.present?
      base << DEFAULT_SYSTEM_PROMPT
      base << AUTO_LANGUAGE_PROMPT if ai_settings['language'] == 'auto'
      base.compact_blank.join("\n")
    end
  end

  def voice_character_prompt
    @voice_character_prompt ||= ai_settings['voice_character_prompt'].to_s.strip
  end

  def voice_character_prompt_block
    "#{VOICE_CHARACTER_PROMPT_LABEL}:\n#{voice_character_prompt}"
  end

  def captain_agent_instructions
    @captain_agent_instructions ||= if fast_captain_voice_prompt?
                                      voice_agent_instructions(fast_captain_voice_prompt)
                                    else
                                      state = captain_runtime_state_for_prompt
                                      context_wrapper = Struct.new(:context).new({ state: state })
                                      voice_agent_instructions(captain_assistant.agent_instructions(context_wrapper))
                                    end
  end

  def fast_captain_voice_prompt?
    !ActiveModel::Type::Boolean.new.cast(ENV.fetch('VOICE_AGENT_FULL_CAPTAIN_PROMPT', nil))
  end

  def fast_captain_voice_prompt
    sections = []
    sections << "Captain assistant: #{captain_assistant.name}" if captain_assistant.name.present?
    sections << captain_assistant.description.to_s.strip if captain_assistant.description.present?
    sections.concat(Array(captain_assistant.system_rule_contents).map { |rule| rule.to_s.strip })
    sections << titled_lines('Response guidelines', captain_assistant.response_guidelines)
    sections << titled_lines('Guardrails', captain_assistant.guardrails)
    sections << titled_scenarios
    sections << titled_context('Current caller context', fast_voice_prompt_context)
    sections.compact_blank.join("\n\n")
  end

  def fast_voice_prompt_context
    {
      conversation: fast_voice_conversation_context,
      contact: fast_voice_contact_context,
      call_session: fast_voice_call_session_context
    }.compact_blank
  end

  def fast_voice_conversation_context
    conversation = session_for_prompt&.conversation
    return if conversation.blank?

    {
      id: conversation.id,
      display_id: conversation.display_id,
      status: conversation.status,
      inbox_id: conversation.inbox_id
    }.compact
  end

  def fast_voice_contact_context
    resolved_contact = session_for_prompt&.contact || contact
    return if resolved_contact.blank?

    {
      id: resolved_contact.id,
      name: resolved_contact.name,
      phone_number: resolved_contact.phone_number
    }.compact_blank
  end

  def fast_voice_call_session_context
    session = session_for_prompt
    return if session.blank?

    {
      id: session.id,
      external_call_ref: session.external_call_ref,
      provider: session.provider,
      direction: session.direction,
      from_number: session.from_number,
      to_number: session.to_number
    }.compact_blank
  end

  def titled_lines(title, values)
    lines = Array(values).map { |value| value.to_s.strip }.compact_blank
    return if lines.blank?

    "#{title}:\n#{lines.join("\n")}"
  end

  def titled_scenarios
    scenarios = captain_scenarios_payload
    return if scenarios.blank?

    lines = scenarios.map do |scenario|
      [scenario[:title], scenario[:key], scenario[:description]].compact_blank.join(' - ')
    end
    titled_lines('Enabled scenarios', lines)
  end

  def titled_context(title, prompt_context)
    entries = %i[conversation contact call_session deal task appointment communication_thread].filter_map do |key|
      value = prompt_context[key]
      next if value.blank?

      "#{key}: #{value.to_json}"
    end
    return if entries.blank?

    "#{title}:\n#{entries.join("\n")}"
  end

  def voice_agent_instructions(prompt)
    stripped = strip_prompt_section(prompt.to_s, 'Tool Artifacts And Attachments')
    stripped = strip_prompt_section(stripped, 'Final Response Contract')
    [stripped, VOICE_RESPONSE_CONTRACT].compact_blank.join("\n")
  end

  def strip_prompt_section(content, heading)
    content.gsub(/\n?# #{Regexp.escape(heading)}\n.*?(?=\n# [^#]|\z)/m, "\n").strip
  end

  def captain_runtime_state_for_prompt
    @captain_runtime_state_for_prompt ||= begin
      state = {
        account_id: account.id,
        assistant_id: captain_assistant.id,
        assistant_config: captain_assistant.config,
        captain_runtime: account.captain_runtime_preferences,
        source: 'voice_ai',
        runtime_clock: runtime_clock_state,
        call_session: { id: session_for_prompt&.id, external_call_ref: session_for_prompt&.external_call_ref }
      }

      if session_for_prompt&.conversation.present?
        state.merge!(
          Captain::ContextFields.runtime_state_for(
            account: account,
            conversation: session_for_prompt.conversation,
            channel_type: session_for_prompt.conversation.inbox&.channel_type
          )
        )
        state[:channel_type] ||= session_for_prompt.conversation.inbox&.channel_type
        state[:reply_window] ||= reply_window_state
      end

      state.compact!
      state[:prompt_context] = captain_assistant.prompt_context_state(state)
      state
    end
  end

  def session_for_prompt
    @session_for_prompt ||= call_session || create_call_session!
  end

  def runtime_clock_state
    timezone = session_for_prompt&.conversation&.inbox&.timezone.presence || Time.zone.name
    timezone = 'UTC' if Time.find_zone(timezone).blank?
    now = Time.current
    local_now = now.in_time_zone(timezone)

    {
      now_utc: now.utc.iso8601,
      now_local: local_now.iso8601,
      timezone: timezone,
      date_local: local_now.to_date.iso8601,
      time_local: local_now.strftime('%H:%M:%S')
    }
  rescue StandardError
    { timezone: 'UTC' }
  end

  def reply_window_state
    conversation = session_for_prompt&.conversation
    return {} unless conversation&.inbox&.channel.is_a?(Channel::Whatsapp)

    last_incoming_at = conversation.messages
                                   .where(account_id: conversation.account_id)
                                   .incoming
                                   .reorder(created_at: :desc)
                                   .limit(1)
                                   .pick(:created_at)
    closes_at = last_incoming_at&.+(Conversations::MessageWindowService::MESSAGING_WINDOW_24_HOURS)

    {
      channel: 'official_whatsapp',
      last_incoming_at: last_incoming_at&.iso8601,
      closes_at: closes_at&.iso8601,
      open_now: closes_at.present? && Time.current < closes_at,
      requires_template_after_close: true
    }.compact
  end

  def ai_settings
    @ai_settings ||= begin
      legacy_settings = (routing_policy&.ai_voice_settings || {}).deep_stringify_keys
      normalized = Telephony::AiVoice::VoiceSettingsDefaults.normalize(legacy_settings.merge(captain_voice_settings))
      channel_limit = routing_policy&.max_call_duration_seconds || Telephony::RoutingPolicy::DEFAULT_MAX_CALL_DURATION_SECONDS
      normalized.merge('max_duration_sec' => [normalized['max_duration_sec'].to_i, channel_limit].min)
    end
  end

  def captain_voice_settings
    @captain_voice_settings ||= (captain_assistant&.config&.dig('voice_settings') || {}).deep_stringify_keys
  end

  def call_session
    return @call_session if defined?(@call_session)

    @call_session = if call_ref.blank?
                      nil
                    elsif prefer_exact_call_ref?
                      exact_call_session_for_call_ref
                    else
                      scoped_payload = params.merge('account_id' => account_id.presence || explicit_number_binding&.account_id)
                      Telephony::AiVoice::CallSessionResolver.new(payload: scoped_payload).call_session
                    end
  end

  def exact_call_session_for_call_ref
    scoped_account = explicit_account || explicit_number_binding&.account
    return scoped_account.telephony_call_sessions.find_by(external_call_ref: call_ref) if scoped_account.present?

    Telephony::CallSession.find_by(external_call_ref: call_ref)
  end

  def prefer_exact_call_ref?
    ActiveModel::Type::Boolean.new.cast(params['prefer_exact_call_ref'] || params['preferExactCallRef'])
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

  def explicit_conversation
    @explicit_conversation ||= begin
      raw_id = params['conversation_id'].presence || params['conversationId'].presence
      if raw_id.present?
        conversation = account.conversations.find_by(id: raw_id)
        conversation || account.conversations.find_by(display_id: raw_id)
      end
    end
  end

  def contact
    @contact ||= if call_session&.contact.present?
                   call_session.contact
                 elsif caller_number.blank? || account.blank?
                   nil
                 else
                   account.contacts.find_by(phone_number: caller_number) || account.contacts.find_by(phone_number: normalized_caller_number)
                 end
  end

  def normalized_caller_number
    @normalized_caller_number ||= Contacts::PhoneNumberNormalizer.normalize(caller_number)
  end

  def call_ref
    params['call_ref'].presence || params['callRef'].presence || params['provider_call_id'].presence || params['providerCallId'].presence
  end

  def provider
    @provider ||= begin
      value = params['provider'].presence || params['telephony_provider'].presence || call_session&.provider || number_binding&.provider
      value.to_s.strip.presence
    end
  end

  def direction
    @direction ||= begin
      value = params['direction'].presence || params['call_direction'].presence || params['callDirection'].presence || call_session&.direction
      value.to_s.presence_in(Telephony::CallSession::ALLOWED_DIRECTIONS) || 'inbound'
    end
  end

  def from_number_for_session
    return caller_number if direction == 'inbound'

    ingress_number || number_binding&.phone_number
  end

  def to_number_for_session
    return ingress_number if direction == 'inbound'

    caller_number
  end

  def transport_name
    @transport_name ||= begin
      explicit = params['transport'].presence || params['media_transport'].presence || params['mediaTransport'].presence
      stored = call_session&.metadata.to_h.dig('ai_voice', 'transport')
      explicit.presence || stored.presence || (provider == 'whatsapp_cloud' ? 'whatsapp_cloud' : 'janus_sip')
    end
  end

  def transport_payload(session)
    {
      provider: session.provider,
      direction: session.direction,
      media: transport_name
    }.compact
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
