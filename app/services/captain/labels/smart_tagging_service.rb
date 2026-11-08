class Captain::Labels::SmartTaggingService
  AUTO_APPLY_THRESHOLD = 0.85
  SOFT_SUGGEST_THRESHOLD = 0.60
  DEFAULT_DECISION_MODEL = 'perplexity/pplx-decider-flash-v1.2'.freeze
  MAX_LABELS = 16
  MAX_MESSAGES = 25

  TRIVIAL_MESSAGE_REGEX = /\A[\s\p{Punct}]*(ок|окей|ok|okay|да|нет|ага|угу|спасибо|спс|рахмет|хорошо|ладно|понял|поняла|здравствуйте|привет|добрый\s+день|добрый\s+вечер|доброе\s+утро|салам|салеметсиз\s+бе|👋|👍|🙏|❤️)+[\s\p{Punct}]*\z/i

  def self.meaningful_message?(message)
    return false if message.blank? || !message.incoming? || message.private?
    return false if message.respond_to?(:voice_call?) && message.voice_call?

    text = message.content.to_s.strip
    return false if text.length < 4
    return false if text.match?(TRIVIAL_MESSAGE_REGEX)

    true
  end

  def self.enabled_for_account?(account)
    return false if account.blank?
    return false if account.captain_features.to_h['label_suggestion'] == false

    account.labels.exists?
  end

  def initialize(conversation:, model: nil)
    @conversation = conversation
    @account = conversation&.account
    @explicit_model = model
  end

  def perform
    return nil unless valid_for_tagging?

    label_records = account.labels.reorder(:id).limit(MAX_LABELS).pluck(:title, :display_title, :description)
    return nil if label_records.empty?

    transcript = build_transcript
    return nil if transcript.blank?

    questions = build_questions(label_records)
    multi_result = ::Llm::Runtime.decide_many(
      feature: :label_suggestion,
      account: account,
      conversation: conversation,
      model: resolved_model,
      input: {
        'conversation_status' => conversation.status,
        'existing_labels' => current_labels,
        'conversation_transcript' => transcript
      },
      options: { decision_questions: questions }
    )

    process_decisions(label_records, multi_result)
  rescue StandardError => e
    Rails.logger.warn("[Captain::Labels::SmartTaggingService] Failed for conversation=#{conversation&.id}: #{e.class}: #{e.message}")
    nil
  end

  private

  attr_reader :conversation, :account, :explicit_model

  def valid_for_tagging?
    return false if conversation.blank? || account.blank?
    return false unless self.class.enabled_for_account?(account)
    return false unless conversation.messages.incoming.where(private: false).exists?

    true
  end

  def resolved_model
    return explicit_model if explicit_model.present? && ::Llm::OpenRouterDecisionClient.supported_model?(explicit_model)

    configured = ::Llm::Config.model_for(feature: :label_suggestion, account: account).presence
    return configured if configured.present? && ::Llm::OpenRouterDecisionClient.supported_model?(configured)

    DEFAULT_DECISION_MODEL
  end

  def build_questions(label_records)
    questions = {}
    label_records.each_with_index do |(title, display_title, description), idx|
      human_name = display_title.to_s.strip.presence || title
      label_ref = human_name.casecmp?(title.to_s) ? "'#{title}'" : "'#{human_name}' (#{title})"
      desc_suffix = description.to_s.strip.present? ? " — #{description.to_s.strip.truncate(120)}" : ''
      questions["label_#{idx}"] = {
        criteria: {
          'apply' => "Label #{label_ref}#{desc_suffix} clearly applies to this conversation.",
          'skip' => "Label #{label_ref} does not apply or there is insufficient evidence."
        },
        instructions: "Decide whether the conversation should be tagged with label #{label_ref}."
      }
    end
    questions
  end

  def process_decisions(label_records, multi_result)
    removed_set = human_removed_labels_set
    active_set = current_labels.map(&:downcase).to_set

    auto_apply = []
    soft_suggest = []

    label_records.each_with_index do |(title, _display_title, _desc), idx|
      normalized = title.to_s.downcase
      next if removed_set.include?(normalized)

      ans = (multi_result.respond_to?(:answers) && multi_result.answers ? multi_result.answers["label_#{idx}"] : nil) || {}
      choice = ans.respond_to?(:choice) ? ans.choice : (ans['choice'] || ans[:choice])
      next unless choice == 'apply'

      conf = ans.respond_to?(:confidence) ? ans.confidence : (ans['confidence'] || ans[:confidence])
      score = conf.nil? ? 1.0 : conf.to_f

      if score >= AUTO_APPLY_THRESHOLD
        auto_apply << title
      elsif score >= SOFT_SUGGEST_THRESHOLD
        soft_suggest << title unless active_set.include?(normalized)
      end
    end

    new_auto_labels = auto_apply.reject { |title| active_set.include?(title.to_s.downcase) }
    apply_labels_to_conversation!(new_auto_labels) if new_auto_labels.any?
    persist_suggestion_metadata!(auto_apply: auto_apply, soft_suggest: soft_suggest)

    {
      auto_applied: auto_apply,
      newly_applied: new_auto_labels,
      suggested: soft_suggest,
      message: soft_suggest.uniq.join(', '),
      usage: multi_result.usage
    }
  end

  def apply_labels_to_conversation!(labels_to_add)
    if conversation.contact.present?
      ::Labels::UnifiedAssignmentService.new(
        contact: conversation.contact,
        conversation: conversation,
        add: labels_to_add,
        silent: true
      ).perform
      conversation.reload
    else
      conversation.add_labels(labels_to_add)
    end
  end

  def persist_suggestion_metadata!(auto_apply:, soft_suggest:)
    attrs = conversation.additional_attributes.to_h.deep_dup
    attrs['ai_auto_applied_labels'] = (Array(attrs['ai_auto_applied_labels']) + auto_apply).uniq
    attrs['ai_suggested_labels'] = soft_suggest
    attrs['ai_labels_evaluated_at'] = Time.current.iso8601
    conversation.update_columns(additional_attributes: attrs)
  end

  def human_removed_labels_set
    Array(conversation.additional_attributes.to_h['human_removed_labels']).map { |l| l.to_s.strip.downcase }.to_set
  end

  def current_labels
    conversation.label_list.to_a
  end

  def build_transcript
    messages = conversation.messages
                           .where(private: false)
                           .where.not(content: [nil, ''])
                           .reorder(created_at: :desc, id: :desc)
                           .limit(MAX_MESSAGES)
                           .reverse

    messages.map do |msg|
      role = msg.incoming? ? 'Customer' : 'Agent'
      "#{role}: #{msg.content.to_s.strip.truncate(400)}"
    end.join("\n")
  end
end
