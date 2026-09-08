# frozen_string_literal: true

# rubocop:disable Metrics/ClassLength
class Captain::Conversation::FollowUpJob < ApplicationJob
  queue_as :captain_runtime

  MAX_STEPS = 5
  PROCESSING_TTL = 1.day
  GENERATED_CONTENT_TTL = 7.days
  TERMINAL_RETENTION = 30.days

  class DeliveryBlocked < StandardError; end

  class QuietHoursDeferred < StandardError
    attr_reader :result

    def initialize(result)
      @result = result
      super('Captain follow-up deferred for quiet hours')
    end
  end


  def self.schedule!(conversation:, assistant:, anchor_message:, step_index:, delay_seconds:, scheduled_at: nil)
    idempotency_key = "captain_follow_up:#{assistant.id}:#{anchor_message.id}:#{step_index}"
    existing_reminder = Reminder.find_by(account: conversation.account, idempotency_key: idempotency_key)
    return existing_reminder if existing_reminder

    Reminder.create!(
      account: conversation.account,
      idempotency_key: idempotency_key,
      conversation: conversation,
      target_conversation: conversation,
      action_type: :captain_follow_up,
      status: :pending,
      scheduled_at: scheduled_at || Time.current + delay_seconds.seconds,
      metadata: {
        'captain_follow_up' => {
          'assistant_id' => assistant.id,
          'anchor_message_id' => anchor_message.id,
          'step_index' => step_index
        }
      }
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    Reminder.find_by(account: conversation.account, idempotency_key: idempotency_key) || raise(e)
  end

  def perform(conversation_id, assistant_id, anchor_message_id, step_index = 0)
    @conversation = Conversation.find_by(id: conversation_id)
    @assistant = Captain::Assistant.find_by(id: assistant_id)
    @anchor_message = @conversation&.messages&.find_by(id: anchor_message_id)
    @step_index = step_index.to_i

    return :skipped unless eligible?
    return :in_progress unless Captain::FollowUpDeliveryConfirmation.acknowledged?(@anchor_message)

    process_follow_up
  rescue DeliveryBlocked => e
    mark_processing_attempt_completed!
    { status: :blocked, reason: e.message }
  rescue QuietHoursDeferred => e
    mark_processing_attempt_failed!
    { status: :deferred, scheduled_at: e.result.next_allowed_at, timezone: e.result.timezone }
  rescue StandardError
    mark_processing_attempt_failed!
    raise
  end

  private

  def process_follow_up
    return :skipped if customer_replied?
    return :skipped if human_intervened?

    existing_message = existing_follow_up_message
    if existing_message
      confirm_delivery(existing_message)
      return :completed
    end

    cached_content = claim_cached_processing_content
    return :in_progress if cached_content == :in_progress

    if cached_content
      blocked = resolve_delivery
      return blocked if blocked

      content = @delivery.template? ? @delivery.content : cached_content
      claim_current, message = materialize_claimed_follow_up(content)
      return :in_progress unless claim_current

      confirm_delivery(message) if message
      return message ? :completed : :skipped
    end

    return :in_progress unless claim_processing_attempt!

    unless conversation_still_needs_follow_up?
      mark_processing_attempt_completed!
      return :skipped
    end

    blocked = resolve_delivery
    return blocked if blocked

    content = follow_up_content
    if content.blank?
      mark_processing_attempt_completed!
      return :skipped
    end

    persist_processing_content!(content)
    claim_current, message = materialize_claimed_follow_up(content)
    return :in_progress unless claim_current
    return :skipped unless message

    confirm_delivery(message)
    :completed
  end

  def resolve_delivery
    @delivery = Captain::FollowUpDeliveryResolver.new(
      conversation: @conversation, assistant: @assistant, step: current_step
    ).call
    return if @delivery.allowed?

    mark_processing_attempt_completed!
    { status: :blocked, reason: @delivery.reason }
  end

  def eligible?
    follow_up_records_present? && anchor_delivery_viable? && valid_step? && conversation_followable? && assistant_connected?
  end

  def follow_up_records_present?
    @conversation.present? && @assistant.present? && @anchor_message.present?
  end

  def anchor_delivery_viable?
    @anchor_message.outgoing? && !@anchor_message.failed?
  end

  def valid_step?
    @step_index.between?(0, MAX_STEPS - 1) &&
      settings['enabled'] == true &&
      current_step.present? && current_step_content_configured?
  end

  def conversation_followable?
    @conversation.open? || @conversation.pending?
  end

  def assistant_connected?
    @assistant.inboxes.exists?(id: @conversation.inbox_id)
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
    return unless attempt&.generated? || attempt&.failed?

    attempt.with_lock do
      attempt.reload
      next unless attempt.generated? || attempt.failed?
      next if attempt.generated_content.blank?
      next if attempt.expires_at.present? && attempt.expires_at <= Time.current
      next :in_progress if active_generated_claim?(attempt)

      attempt.update!(
        status: :generated,
        processing_started_at: next_processing_claim_started_at(attempt)
      )
      @processing_attempt = attempt
      remember_processing_claim!
      attempt.generated_content
    end
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
    @steps ||= Array(settings['steps']).first(MAX_STEPS).map { |step| step.to_h.deep_stringify_keys }
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

    raise Reminders::RetryableExecutionError, 'Captain follow-up completion check was unavailable' unless result[:evaluated] == true

    result[:complete] != true
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
    return @delivery.content if @delivery&.template?
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
      step_index: @step_index,
      temporal_context: temporal_context
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

    @conversation.with_lock do
      existing_message = existing_follow_up_message
      next existing_message if existing_message
      next if customer_replied? || human_intervened? || !conversation_followable?
      next if duplicate_content?(content)

      quiet_hours = Captain::FollowUpQuietHoursPolicy.new(assistant: @assistant, conversation: @conversation).call
      raise QuietHoursDeferred, quiet_hours if quiet_hours.quiet?

      blocked = resolve_delivery
      raise DeliveryBlocked, blocked[:reason] if blocked

      create_follow_up_message!(@delivery.template? ? @delivery.content : content)
    end
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
    @conversation.messages.create!(
      message_type: :outgoing,
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      sender: @assistant,
      content: content,
      additional_attributes: follow_up_attributes
    )
  end

  def follow_up_attributes
    attributes = {
      'captain_follow_up' => {
        'assistant_id' => @assistant.id,
        'step_index' => @step_index,
        'anchor_message_id' => @anchor_message.id,
        'mode' => static_step? ? 'static' : 'ai',
        'objective' => current_step['objective'].to_s.strip.presence,
        'language' => temporal_context[:language],
        'timezone' => temporal_context[:timezone],
        'day_period' => temporal_context[:day_period],
        'relative_day' => temporal_context[:relative_day],
        'delivery_mode' => @delivery&.mode,
        'generator_version' => static_step? ? nil : 'v1',
        'prompt_fingerprint' => static_step? ? nil : follow_up_prompt_fingerprint
      }
    }
    agent_name = @anchor_message.additional_attributes.to_h['agent_name'].to_s.presence
    attributes['agent_name'] = agent_name if agent_name
    attributes['template_params'] = @delivery.template_params if @delivery&.template?
    attributes['delivery_policy'] = @delivery.policy.as_json if @delivery&.policy
    attributes
  end

  def temporal_context
    @temporal_context ||= Captain::FollowUpTemporalContext.new(
      conversation: @conversation,
      assistant: @assistant
    ).as_json
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

  def confirm_delivery(message)
    Captain::FollowUpDeliveryConfirmation.new(message: message).perform
  end
end
# rubocop:enable Metrics/ClassLength
