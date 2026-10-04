# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
class Captain::Conversation::FollowUpJob < ApplicationJob
  queue_as :captain_runtime

  PROCESSING_TTL = 1.day
  GENERATED_CONTENT_TTL = 7.days
  TERMINAL_RETENTION = 30.days

  def self.eligible_anchor_message?(anchor_message:, assistant:)
    attributes = anchor_message.additional_attributes.to_h.deep_stringify_keys
    ai_reply = attributes['captain_ai_reply'].is_a?(Hash) ? attributes['captain_ai_reply'].deep_stringify_keys : {}
    follow_up = attributes['captain_follow_up'].is_a?(Hash) ? attributes['captain_follow_up'].deep_stringify_keys : {}

    ai_reply['assistant_id'].to_i == assistant.id ||
      (follow_up['assistant_id'].to_i == assistant.id && follow_up['step_index'].present?)
  end

  def self.schedule!(conversation:, assistant:, anchor_message:, step:, control_fence:)
    payload = build_schedule_payload(conversation, assistant, anchor_message, step, control_fence)
    return unless payload[:step][:delay_seconds].positive?

    conversation.with_lock { schedule_reminder!(payload) }
  rescue ActiveRecord::RecordNotUnique
    Reminder.find_by(account: conversation.account, idempotency_key: payload[:idempotency_key])
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[CAPTAIN][FollowUpJob] Follow-up scheduling rejected: #{e.record.errors.full_messages.join(', ')}")
    nil
  end

  def self.build_schedule_payload(conversation, assistant, anchor_message, step, control_fence)
    normalized_step = step.to_h.with_indifferent_access
    step_data = { index: normalized_step[:index].to_i, delay_seconds: normalized_step[:delay_seconds].to_i }
    {
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor_message,
      step: step_data,
      control_fence: normalize_control_fence(control_fence),
      idempotency_key: "captain_follow_up:#{assistant.id}:#{anchor_message.id}:#{step_data[:index]}"
    }
  end

  def self.schedule_reminder!(payload)
    conversation = payload[:conversation]
    existing = Reminder.find_by(account: conversation.account, idempotency_key: payload[:idempotency_key])
    return existing if existing

    reminder = build_reminder(payload)
    return unless Captain::Conversation::FollowUpGuard.current?(
      reminder: reminder,
      conversation: conversation,
      assistant: payload[:assistant],
      anchor_message: payload[:anchor_message]
    )

    reminder.save!
    reminder
  end

  def self.build_reminder(payload)
    reminder = Reminder.new(reminder_attributes(payload))
    reminder.internal_captain_follow_up_write = true
    reminder
  end

  def self.reminder_attributes(payload)
    conversation = payload[:conversation]
    {
      account: conversation.account,
      idempotency_key: payload[:idempotency_key],
      conversation: conversation,
      target_conversation: conversation,
      action_type: :captain_follow_up,
      status: :pending,
      auto_cancel_on_incoming: true,
      scheduled_at: Time.current + payload[:step][:delay_seconds].seconds,
      metadata: reminder_metadata(payload)
    }
  end

  def self.reminder_metadata(payload)
    {
      'auto_cancel_on_incoming_explicit' => true,
      'captain_follow_up' => {
        'assistant_id' => payload[:assistant].id,
        'anchor_message_id' => payload[:anchor_message].id,
        'step_index' => payload[:step][:index],
        'control_fence' => payload[:control_fence]
      }
    }
  end

  def self.normalize_control_fence(value)
    fence = value.to_h.with_indifferent_access
    %i[control_generation status_transition_id last_message_id].index_with { |key| fence[key] }.compact.stringify_keys
  end

  def self.schedule_after_delivery!(reminder:, message:)
    context = next_step_context(reminder)
    return unless context

    step = configured_next_step(context[:settings], context[:step_index])
    return unless step

    schedule!(
      conversation: context[:conversation],
      assistant: context[:assistant],
      anchor_message: message,
      step: { index: context[:step_index], delay_seconds: step['delay_seconds'] },
      control_fence: context[:control_fence]
    )
  end

  def self.next_step_context(reminder)
    metadata = reminder.metadata.to_h.deep_stringify_keys.fetch('captain_follow_up', {}).to_h
    assistant = Captain::Assistant.find_by(id: metadata['assistant_id'], account_id: reminder.account_id)
    conversation = Conversation.find_by(id: reminder.target_conversation_id, account_id: reminder.account_id)
    anchor = Message.find_by(id: metadata['anchor_message_id'], account_id: reminder.account_id)
    return unless assistant && conversation && anchor

    fence = Captain::Conversation::FollowUpControlFence.resolve(
      reminder: reminder,
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor
    )
    return if fence.blank?

    {
      assistant: assistant,
      conversation: conversation,
      settings: assistant.config.to_h.deep_stringify_keys['follow_up_settings'].to_h,
      step_index: metadata['step_index'].to_i + 1,
      control_fence: fence
    }
  end

  def self.configured_next_step(settings, step_index)
    return unless settings['enabled'] == true

    step = Array(settings['steps'])[step_index]
    return unless step.is_a?(Hash)

    step = step.deep_stringify_keys
    return unless step['delay_seconds'].to_i.positive? && step_configured?(settings, step)

    step
  end

  def self.step_configured?(settings, step)
    static = step['mode'].to_s == 'static' || (step['mode'].blank? && step['message'].to_s.strip.present?)
    return step['message'].to_s.strip.present? if static

    settings['prompt'].to_s.strip.present? && step['objective'].to_s.strip.present?
  end

  def self.legacy_conversation_plan_pending?(conversation)
    conversation.account.reminders.active_delivery_or_open
                .where.not(reminder_group_id: nil)
                .exists?([
                           'conversation_id = :conversation_id OR target_conversation_id = :conversation_id',
                           { conversation_id: conversation.id }
                         ])
  end

  def perform(_conversation_id, _assistant_id, _anchor_message_id, _step_index = 0)
    raise ArgumentError, 'Captain follow-up steps must execute through Reminders::ExecuteService'
  end

  def perform_for_reminder(reminder:, conversation:, assistant:, anchor_message:, delivery:)
    @reminder = reminder
    @conversation = conversation
    @assistant = assistant
    @anchor_message = anchor_message
    @delivery = delivery
    follow_up = reminder.metadata.to_h.deep_stringify_keys.fetch('captain_follow_up', {}).to_h
    @step_index = follow_up['step_index'].to_i
    @control_fence = Captain::Conversation::FollowUpGuard.control_fence_for(
      reminder: reminder,
      conversation: conversation,
      assistant: assistant,
      anchor_message: anchor_message
    ).to_h.deep_stringify_keys

    return :skipped unless eligible?

    process_follow_up
  rescue StandardError
    mark_processing_attempt_failed!
    raise
  end

  private

  def process_follow_up
    return :skipped if customer_or_human_replied?

    existing_message = existing_follow_up_message
    return existing_message if existing_message

    cached_content = claim_cached_processing_content
    return cached_content_result(cached_content) if cached_content.present?
    return :in_progress unless claim_processing_attempt!

    generate_and_materialize_follow_up
  end

  def customer_or_human_replied?
    customer_replied? || human_intervened?
  end

  def cached_content_result(content)
    return :in_progress if content == :in_progress

    materialize_content(content)
  end

  def generate_and_materialize_follow_up
    return complete_attempt_without_message unless conversation_still_needs_follow_up?

    content = follow_up_content
    return complete_attempt_without_message if content.blank?

    persist_processing_content!(content)
    materialize_content(content)
  end

  def complete_attempt_without_message
    mark_processing_attempt_completed!
    :skipped
  end

  def materialize_content(content)
    claim_current, message = materialize_claimed_follow_up(content)
    return :in_progress unless claim_current

    message || :skipped
  end

  def eligible?
    follow_up_records_present? && anchor_delivery_viable? && valid_step? &&
      Captain::Conversation::FollowUpGuard.current?(
        reminder: @reminder,
        conversation: @conversation,
        assistant: @assistant,
        anchor_message: @anchor_message
      )
  end

  def follow_up_records_present?
    @conversation.present? && @assistant.present? && @anchor_message.present? && @delivery.present?
  end

  def anchor_delivery_viable?
    @anchor_message.outgoing? && !@anchor_message.private? && !@anchor_message.failed?
  end

  def valid_step?
    @step_index >= 0 && @step_index < steps.length &&
      settings['enabled'] == true &&
      current_step.present? && current_step_content_configured?
  end

  def settings
    @settings ||= @assistant.config.to_h.deep_stringify_keys.fetch('follow_up_settings', {}).to_h
  end

  def claim_processing_attempt!
    expire_and_prune_terminal_attempts!
    @processing_attempt = Captain::FollowUpAttempt.create_or_find_by!(attempt_key: processing_attempt_key) do |attempt|
      attempt.assign_attributes(
        account: @conversation.account,
        assistant: @assistant,
        conversation: @conversation,
        anchor_message: @anchor_message,
        step_index: @step_index,
        status: :processing,
        processing_started_at: Time.current,
        expires_at: PROCESSING_TTL.from_now
      )
    end
    if @processing_attempt.previously_new_record?
      remember_processing_claim!
      return true
    end

    reclaim_processing_attempt!
  end

  def reclaim_processing_attempt!
    @processing_attempt.with_lock do
      @processing_attempt.reload
      next false unless reclaimable_processing_attempt?

      @processing_attempt.update!(
        status: :processing,
        generated_content: nil,
        generated_at: nil,
        completed_at: nil,
        processing_started_at: next_processing_claim_started_at(@processing_attempt),
        expires_at: PROCESSING_TTL.from_now
      )
      remember_processing_claim!
      true
    end
  end

  def reclaimable_processing_attempt?
    return true if @processing_attempt.failed? && @processing_attempt.generated_content.blank?
    return true if @processing_attempt.expired?

    @processing_attempt.processing? && @processing_attempt.expires_at.present? && @processing_attempt.expires_at <= Time.current
  end

  def processing_attempt_key
    Digest::SHA256.hexdigest(
      [@conversation.id, @anchor_message.id, @assistant.id, @step_index, settings['prompt'], current_step]
        .map(&:to_s)
        .join("\n")
    )
  end

  def claim_cached_processing_content
    attempt = processing_attempt
    return unless cached_attempt?(attempt)

    attempt.with_lock do
      attempt.reload
      next unless usable_cached_attempt?(attempt)
      next :in_progress if active_generated_claim?(attempt)

      claim_cached_attempt!(attempt)
    end
  end

  def cached_attempt?(attempt)
    attempt&.generated? || attempt&.failed?
  end

  def usable_cached_attempt?(attempt)
    cached_attempt?(attempt) && attempt.generated_content.present? &&
      (attempt.expires_at.blank? || attempt.expires_at > Time.current)
  end

  def claim_cached_attempt!(attempt)
    attempt.update!(
      status: :generated,
      processing_started_at: next_processing_claim_started_at(attempt)
    )
    @processing_attempt = attempt
    remember_processing_claim!
    attempt.generated_content
  end

  def active_generated_claim?(attempt)
    attempt.generated? && attempt.processing_started_at.present? &&
      attempt.processing_started_at > PROCESSING_TTL.ago
  end

  def persist_processing_content!(content)
    processing_attempt.with_lock do
      processing_attempt.reload
      raise 'Captain follow-up processing claim was lost' unless current_processing_claim?

      processing_attempt.update!(
        generated_content: content,
        status: :generated,
        generated_at: Time.current,
        expires_at: GENERATED_CONTENT_TTL.from_now
      )
    end
  end

  def processing_attempt
    @processing_attempt ||= Captain::FollowUpAttempt.find_by(attempt_key: processing_attempt_key)
  end

  def materialize_claimed_follow_up(content)
    processing_attempt.with_lock do
      processing_attempt.reload
      next [false, nil] unless current_processing_claim?

      message = find_or_create_follow_up_message(content)
      processing_attempt.update!(status: :completed, completed_at: Time.current)
      [true, message]
    end
  end

  def mark_processing_attempt_completed!
    return if processing_attempt.blank?

    processing_attempt.with_lock do
      processing_attempt.reload
      next if @processing_claim_started_at.present? && !current_processing_claim?

      processing_attempt.update!(status: :completed, completed_at: Time.current)
    end
  end

  def mark_processing_attempt_failed!
    return if @processing_attempt.blank? || @processing_claim_started_at.blank?

    @processing_attempt.with_lock do
      @processing_attempt.reload
      next unless current_processing_claim?
      next if @processing_attempt.completed? || @processing_attempt.expired?

      @processing_attempt.update!(status: :failed)
    end
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][FollowUpJob] Failed to persist attempt failure: #{e.class}")
  end

  def remember_processing_claim!
    @processing_claim_started_at = @processing_attempt.processing_started_at
  end

  def next_processing_claim_started_at(attempt)
    now = Time.current
    previous = attempt.processing_started_at
    return now if previous.blank? || now > previous

    previous + 1.microsecond
  end

  def current_processing_claim?
    @processing_attempt.processing_started_at == @processing_claim_started_at
  end

  def expire_and_prune_terminal_attempts!
    scope = Captain::FollowUpAttempt.where(anchor_message_id: @anchor_message.id)
    scope.where(status: %w[processing generated], expires_at: ..Time.current).update_all( # rubocop:disable Rails/SkipsModelValidations
      status: Captain::FollowUpAttempt.statuses[:expired],
      updated_at: Time.current
    )
    scope.where(status: %w[completed failed expired], updated_at: ...TERMINAL_RETENTION.ago).delete_all
  end

  def steps
    @steps ||= Array(settings['steps']).map { |step| step.to_h.deep_stringify_keys }
  end

  def current_step
    steps[@step_index]
  end

  def customer_replied?
    @conversation.messages.incoming.exists?(['id > ?', @anchor_message.id])
  end

  def human_intervened?
    @conversation.messages.outgoing
                 .where(private: false, sender_type: 'User')
                 .exists?(['id > ?', @anchor_message.id])
  end

  def conversation_still_needs_follow_up?
    result = Captain::ConversationCompletionEvaluator.new(
      account: @conversation.account,
      conversation_display_id: @conversation.display_id,
      messages: completion_messages
    ).perform

    evaluation = result.to_h.with_indifferent_access
    unless evaluation[:evaluated] == true
      Rails.logger.warn("[CAPTAIN][FollowUpJob] Completion check was not evaluated: #{evaluation[:reason].to_s.presence || 'unknown'}")
      return false
    end

    evaluation[:complete] != true
  rescue Reminders::RetryableExecutionError
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][FollowUpJob] Completion check failed: #{e.class}")
    raise Reminders::RetryableExecutionError, 'Captain follow-up completion check failed'
  end

  def completion_messages
    @conversation.messages
                 .where(private: false)
                 .where(message_type: [:incoming, :outgoing])
                 .order(created_at: :asc)
                 .last(30)
                 .filter_map do |message|
      next if message.content.blank?

      {
        role: message.incoming? ? 'user' : 'assistant',
        content: message.content
      }
    end
  end

  def current_step_content_configured?
    return current_step['message'].to_s.strip.present? if static_step?

    settings['prompt'].to_s.strip.present? && current_step['objective'].to_s.strip.present?
  end

  def static_step?
    current_step['mode'].to_s == 'static' ||
      (current_step['mode'].blank? && current_step['message'].to_s.strip.present?)
  end

  def follow_up_content
    return current_step['message'].to_s.strip if static_step?

    generated_content(follow_up_generator.perform)
  rescue Reminders::RetryableExecutionError
    raise
  rescue StandardError => e
    Rails.logger.warn("[CAPTAIN][FollowUpJob] Message generation failed: #{e.class.name}")
    raise Reminders::RetryableExecutionError, 'Captain follow-up message generation failed'
  end

  def follow_up_generator
    Captain::FollowUpMessageGenerator.new(
      account: @conversation.account,
      assistant: @assistant,
      conversation_display_id: @conversation.display_id,
      messages: completion_messages,
      settings: settings,
      step: current_step,
      scenario: active_scenario,
      step_index: @step_index
    )
  end

  def generated_content(result)
    return result[:message].to_s.strip if result[:generated] == true

    Rails.logger.warn(
      "[CAPTAIN][FollowUpJob] Message generation failed: #{result[:error].to_s.presence || 'unknown'}"
    )
    raise Reminders::RetryableExecutionError, 'Captain follow-up message generation was unavailable'
  end

  def active_scenario
    agent_name = @anchor_message.additional_attributes.to_h['agent_name'].to_s
    return if agent_name.blank?

    @assistant.scenarios.enabled.find_by(handoff_key: agent_name)
  end

  def find_or_create_follow_up_message(content)
    return if content.blank?

    existing_message = existing_follow_up_message
    return existing_message if existing_message
    return if customer_replied? || human_intervened?
    return unless Captain::Conversation::FollowUpGuard.current?(
      reminder: @reminder,
      conversation: @conversation,
      assistant: @assistant,
      anchor_message: @anchor_message
    )
    return if duplicate_content?(content)

    create_follow_up_message!(content)
  end

  def duplicate_content?(content)
    normalized_content = normalize_content(content)
    @conversation.messages.outgoing.where(private: false).order(id: :desc).limit(10).any? do |message|
      normalize_content(message.content) == normalized_content
    end
  end

  def normalize_content(content)
    content.to_s.squish.downcase
  end

  def create_follow_up_message!(content)
    message = @delivery.call(content, follow_up_attributes)
    return unless valid_materialized_follow_up?(message)

    message
  end

  def valid_materialized_follow_up?(message)
    return false unless message.is_a?(Message) && follow_up_message_owner_matches?(message)
    return false unless follow_up_message_is_public?(message)

    follow_up_marker_matches?(message)
  end

  def follow_up_message_owner_matches?(message)
    follow_up_message_scope_matches?(message) && follow_up_message_sender_matches?(message)
  end

  def follow_up_message_scope_matches?(message)
    message.account_id == @reminder.account_id &&
      message.conversation_id == @conversation.id && message.inbox_id == @conversation.inbox_id
  end

  def follow_up_message_sender_matches?(message)
    message.sender_type == @assistant.class.name && message.sender_id == @assistant.id
  end

  def follow_up_message_is_public?(message)
    message.outgoing? && !message.private? && !message.failed?
  end

  def follow_up_marker_matches?(message)
    marker = message.additional_attributes.to_h.deep_stringify_keys['captain_follow_up'].to_h
    marker['assistant_id'].to_i == @assistant.id &&
      marker['anchor_message_id'].to_i == @anchor_message.id &&
      marker['step_index'].to_i == @step_index
  end

  def follow_up_attributes
    attributes = {
      'captain_follow_up' => {
        'assistant_id' => @assistant.id,
        'step_index' => @step_index,
        'anchor_message_id' => @anchor_message.id,
        'mode' => static_step? ? 'static' : 'ai',
        'objective' => current_step['objective'].to_s.strip.presence,
        'generator_version' => static_step? ? nil : 'v1',
        'prompt_fingerprint' => static_step? ? nil : follow_up_prompt_fingerprint,
        'control_fence' => @control_fence
      }
    }
    agent_name = @anchor_message.additional_attributes.to_h['agent_name'].to_s.presence
    attributes['agent_name'] = agent_name if agent_name
    attributes
  end

  def follow_up_prompt_fingerprint
    Digest::SHA256.hexdigest([settings['prompt'], current_step['objective']].join("\n"))
  end

  def existing_follow_up_message
    @conversation.messages.outgoing.where('id > ?', @anchor_message.id).find do |message|
      marker = message.additional_attributes.to_h['captain_follow_up'].to_h
      marker['assistant_id'].to_i == @assistant.id &&
        marker['step_index'].to_i == @step_index &&
        marker['anchor_message_id'].to_i == @anchor_message.id
    end
  end
end
# rubocop:enable Metrics/ClassLength
