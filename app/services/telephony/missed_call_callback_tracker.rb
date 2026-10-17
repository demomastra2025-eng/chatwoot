# frozen_string_literal: true

class Telephony::MissedCallCallbackTracker
  UNANSWERED_TERMINAL_STATUSES = %w[
    missed
    no_answer
    no-answer
    busy
    cancelled
    canceled
    failed
    rejected
    declined
  ].freeze

  ANSWERED_STATUSES = %w[
    in_progress
    in-progress
    completed
  ].freeze

  class << self
    def unanswered_inbound_terminal?(call_session)
      return false if call_session.blank?
      return false unless call_session.direction.to_s == 'inbound'
      return false unless call_session.terminal?
      return false if call_session.answered_at.present?
      return false if call_session.end_reason.to_s == Telephony::SiblingLegCloser::END_REASON
      return false unless UNANSWERED_TERMINAL_STATUSES.include?(call_session.canonical_status.to_s)

      if call_session.respond_to?(:logical_group_sessions)
        group_sessions = Array(call_session.logical_group_sessions)
        return false if group_sessions.any? { |session| session_answered?(session) }
        return false unless group_sessions.all?(&:terminal?)
      end

      true
    end

    def answered_call?(call_session)
      return false if call_session.blank?
      return false if call_session.end_reason.to_s == Telephony::SiblingLegCloser::END_REASON

      session_answered?(call_session)
    end

    def waiting_for_callback?(conversation)
      return false if conversation.blank?

      custom = conversation.custom_attributes.to_h
      additional = conversation.additional_attributes.to_h
      ActiveModel::Type::Boolean.new.cast(custom['waiting_for_callback']) == true ||
        ActiveModel::Type::Boolean.new.cast(additional['waiting_for_callback']) == true
    end

    def sync_for_call_session!(call_session)
      return :noop if call_session.blank? || call_session.conversation.blank?

      if unanswered_inbound_terminal?(call_session)
        mark_waiting_for_callback!(call_session)
        :missed_marked
      elsif answered_call?(call_session)
        clear_for_contact!(
          account: call_session.account,
          contact_id: call_session.contact_id || call_session.conversation&.contact_id,
          primary_conversation: call_session.conversation
        )
        :callback_cleared
      else
        :noop
      end
    rescue StandardError => e
      Rails.logger.warn(
        "TELEPHONY_MISSED_CALL_TRACKER_ERROR call_ref=#{call_session&.external_call_ref} " \
        "error=#{e.class.name}: #{e.message}"
      )
      :error
    end

    def clear_on_outgoing_message!(message)
      return false if message.blank? || message.private? || !message.outgoing? || message.voice_call?
      return false if message.automated_outbound_message?
      return false if ActiveModel::Type::Boolean.new.cast(message.additional_attributes.to_h['missed_call_whatsapp_followup'])

      conversation = message.conversation
      return false if conversation.blank?

      contact_id = conversation.contact_id
      clear_for_contact!(
        account: message.account,
        contact_id: contact_id,
        primary_conversation: conversation
      )
    rescue StandardError => e
      Rails.logger.warn(
        "TELEPHONY_MISSED_CALL_CLEAR_ON_MESSAGE_ERROR message_id=#{message&.id} " \
        "error=#{e.class.name}: #{e.message}"
      )
      false
    end

    def mark_waiting_for_callback!(call_session)
      conversation = call_session.conversation
      return false if conversation.blank?

      custom = (conversation.custom_attributes || {}).deep_dup
      additional = (conversation.additional_attributes || {}).deep_dup

      custom['waiting_for_callback'] = true
      additional['waiting_for_callback'] = true
      additional['last_missed_call_ref'] = call_session.external_call_ref
      additional['last_missed_call_at'] = (call_session.ended_at || Time.current).iso8601

      conversation.update!(
        custom_attributes: custom,
        additional_attributes: additional
      )
      refresh_thread_if_present!(conversation)
      true
    end

    def clear_for_contact!(account:, contact_id:, primary_conversation: nil)
      return false if account.blank?

      waiting_sql = "COALESCE(conversations.additional_attributes ->> 'waiting_for_callback', conversations.custom_attributes ->> 'waiting_for_callback') = 'true'"
      conversations = if contact_id.present?
                        account.conversations.where(contact_id: contact_id).where(waiting_sql).to_a
                      elsif primary_conversation.present? && waiting_for_callback?(primary_conversation)
                        [primary_conversation]
                      else
                        []
                      end

      return false if conversations.empty?

      conversations.each do |conv|
        custom = (conv.custom_attributes || {}).deep_dup
        additional = (conv.additional_attributes || {}).deep_dup
        custom['waiting_for_callback'] = false
        additional['waiting_for_callback'] = false
        conv.update!(
          custom_attributes: custom,
          additional_attributes: additional
        )
        clear_voice_messages_waiting_flag!(conv)
        refresh_thread_if_present!(conv)
      end

      true
    end

    private

    def session_answered?(session)
      session.answered_at.present? ||
        ANSWERED_STATUSES.include?(session.canonical_status.to_s)
    end

    def clear_voice_messages_waiting_flag!(conversation)
      conversation.messages.voice_calls.find_each do |msg|
        raw = msg.content_attributes
        attrs = raw.is_a?(Hash) ? raw.deep_dup.deep_stringify_keys : {}
        next unless attrs.dig('data', 'waiting_for_callback') == true

        attrs['data']['waiting_for_callback'] = false
        msg.update!(content_attributes: attrs)
      end
    end

    def refresh_thread_if_present!(conversation)
      return unless conversation.account&.feature_enabled?('communication_threads')

      conversation.refresh_communication_thread!
    rescue StandardError
      nil
    end
  end
end
