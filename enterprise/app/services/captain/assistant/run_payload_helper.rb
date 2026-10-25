# frozen_string_literal: true

module Captain::Assistant::RunPayloadHelper
  private

  def build_context(message_history)
    context = {
      session_id: captain_session_id,
      conversation_history: normalize_history(message_history),
      state: build_state
    }
    # A caller with an id of its own (a reply suggestion request) gives it to the run: all llm events of the run share it.
    context[:agent_request_id] = @request_id if @request_id.present?
    @assistant.persisted? ? agent_run_context.prepare(context) : context
  end

  def captain_session_id
    thread_id = @conversation&.communication_thread&.id
    return "#{@assistant.account_id}_thread_#{thread_id}" if thread_id.present?

    "#{@assistant.account_id}_#{@conversation&.display_id}"
  end

  def extract_last_user_message(message_history)
    last_user_msg = message_history.reverse.find { |msg| message_role(msg) == 'user' }
    return '' if last_user_msg.blank?

    content = message_value(last_user_msg, :content)
    return extract_text_from_content(content) unless content.is_a?(Array) || content.is_a?(RubyLLM::Content)

    built_content = Llm::MessageFormat.build_content(content)
    return built_content unless built_content.is_a?(RubyLLM::Content) && built_content.attachments.blank?

    built_content.text
  end

  def message_history_without_last_user_message(message_history)
    last_user_index = message_history.rindex { |msg| message_role(msg) == 'user' }
    return message_history if last_user_index.nil?

    message_history.reject.with_index { |_msg, index| index == last_user_index }
  end

  # The customer messages after the agent's last reply, other than the one being answered, reach the model as history
  # (a document followed by "ok", several messages sent in a row). The input guardrails read them with the current message.
  # With none of them the current message is returned unchanged.
  def input_with_unanswered_messages(message_to_process, context)
    earlier_texts = unanswered_user_texts(context)
    return message_to_process if earlier_texts.empty?

    current_text = message_to_process.is_a?(RubyLLM::Content) ? message_to_process.text : message_to_process
    # The current message goes first because the moderation call keeps only the start of a long text.
    [current_text, *earlier_texts].map { |text| { type: 'text', text: text.to_s } }
  end

  def unanswered_user_texts(context)
    unanswered = Array(context[:conversation_history]).reverse.take_while { |entry| message_role(entry) == 'user' }
    unanswered.reverse.filter_map { |entry| extract_text_from_content(message_value(entry, :content)).to_s.presence }
  end

  def extract_text_from_content(content)
    return content[:response] || content['response'] || content.to_s if content.is_a?(Hash)
    return content unless content.is_a?(Array) || content.is_a?(RubyLLM::Content)

    text, = Llm::MessageFormat.extract_text_and_attachments(content)
    text.to_s
  end

  def normalize_history(message_history)
    message_history.filter_map do |message|
      role = message_role(message)
      next if role.blank?

      {
        role: role.to_sym,
        content: stamped_content(normalized_message_content(message), message),
        agent_name: message_value(message, :agent_name),
        tool_calls: message_value(message, :tool_calls),
        tool_call_id: message_value(message, :tool_call_id)
      }.compact
    end
  end

  def normalized_message_content(message)
    content = message_value(message, :content)
    return content if content.is_a?(Array)

    extract_text_from_content(content)
  end

  # A message of the conversation (the history builders give its sent_at) starts with its send time in the zone of the run,
  # "[Sat 24.10 09:50] Можно завтра?": the model reads a patient's "today" or "tomorrow" from the day it was written, not from the
  # clock of the run. The message being answered is the input of the run and stays unstamped (the guardrails, the router and the
  # lookups read its text); its time reaches the prompt as message_sent_at of the run clock (see last_user_message_sent_at).
  def stamped_content(content, message)
    stamp = Captain::PromptClock.message_stamp(message_value(message, :sent_at), history_time_zone)
    return content if stamp.blank?
    return "#{stamp} #{content}" if content.is_a?(String)
    return content unless content.is_a?(Array)

    first = content.first
    text_key = text_part_key(first)
    return [{ type: 'text', text: stamp }, *content] unless text_key

    [first.merge(text_key => "#{stamp} #{first[text_key]}"), *content.drop(1)]
  end

  # :text or 'text' when the part is a text part, else nil.
  def text_part_key(part)
    return unless part.is_a?(Hash) && (part[:type] || part['type']).to_s == 'text'

    part.key?(:text) ? :text : 'text'
  end

  # The send time of the message being answered (the last message of the patient), as the history builders give it; nil when the
  # history carries no time (a Playground run, a campaign message).
  def last_user_message_sent_at(message_history)
    last_user_msg = message_history.reverse.find { |msg| message_role(msg) == 'user' }
    message_value(last_user_msg, :sent_at) if last_user_msg
  end

  def history_time_zone
    @history_time_zone ||= respond_to?(:runtime_timezone, true) ? runtime_timezone : nil
  end

  def message_role(message)
    message_value(message, :role).to_s.presence
  end

  def message_value(message, key)
    message[key] || message[key.to_s]
  end
end
