class Captain::LabelSuggestionService < Captain::BaseTaskService
  pattr_initialize [:account!, :conversation_display_id!]

  def perform
    # Check cache first
    cached_response = read_from_cache
    return cached_response if cached_response.present?

    if Llm::OpenRouterDecisionClient.supported_model?(task_model)
      decision_response = perform_with_decision_model
      if decision_response.present? && decision_response[:error].blank?
        write_to_cache(decision_response)
        return decision_response
      end
    end

    # Build content for legacy chat fallback
    content = labels_with_messages
    return nil if content.blank?

    # Make API call
    response = make_api_call(
      model: task_model,
      messages: [
        { role: 'system', content: render_task_prompt('label_suggestion') },
        { role: 'user', content: content }
      ]
    )
    return response if response[:error].present?

    # Clean up response
    result = { message: response[:message] ? response[:message].gsub(/^(label|labels):/i, '') : '' }

    # Cache successful result
    write_to_cache(result)

    result
  end

  private

  def perform_with_decision_model
    return nil unless conversation.present?

    smart_result = Captain::Labels::SmartTaggingService.new(
      conversation: conversation,
      model: task_model
    ).perform
    return nil if smart_result.blank?

    {
      message: Array(smart_result[:suggested]).join(', '),
      auto_applied: Array(smart_result[:auto_applied]),
      newly_applied: Array(smart_result[:newly_applied]),
      suggested: Array(smart_result[:suggested]),
      usage: smart_result[:usage]
    }
  rescue StandardError => e
    Rails.logger.warn("[Captain::LabelSuggestionService] Decision model fallback: #{e.class}: #{e.message}")
    nil
  end

  def cache_key
    return nil unless conversation

    format(
      ::Redis::Alfred::OPENAI_CONVERSATION_KEY,
      event_name: 'label_suggestion',
      conversation_id: conversation.id,
      updated_at: conversation.last_activity_at.to_i
    )
  end

  def read_from_cache
    return nil unless cache_key

    cached = Redis::Alfred.get(cache_key)
    JSON.parse(cached, symbolize_names: true) if cached.present?
  rescue JSON::ParserError
    nil
  end

  def write_to_cache(response)
    Redis::Alfred.setex(cache_key, response.to_json) if cache_key
  end

  def labels_with_messages
    return nil unless valid_conversation?(conversation)

    labels = account.labels.pluck(:title).join(', ')
    messages = format_messages_as_string(start_from: labels.length)

    return nil if messages.blank? || labels.blank?

    "Messages:\n#{messages}\nLabels:\n#{labels}"
  end

  def format_messages_as_string(start_from: 0)
    messages = conversation_messages(start_from: start_from)
    messages.map do |msg|
      sender_type = msg[:role] == 'user' ? 'Customer' : 'Agent'
      "#{sender_type}: #{msg[:content]}\n"
    end.join
  end

  def valid_conversation?(conversation)
    return false if conversation.nil?
    return false if conversation.messages.incoming.count < 3
    return false if conversation.messages.count > 100
    return false if conversation.messages.count > 20 && !conversation.messages.last.incoming?

    true
  end

  def event_name
    'label_suggestion'
  end

  def llm_feature_key
    'label_suggestion'
  end

  def build_follow_up_context?
    false
  end
end
