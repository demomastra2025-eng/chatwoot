class Outbound::PlaygroundDeliveryPolicy
  ATTRIBUTE_KEY = 'captain_playground'.freeze
  BLOCKED_MESSAGE = 'External delivery is disabled for this Playground run'.freeze
  PURPOSE = 'captain_playground_delivery_v1'.freeze
  PHONE_CHANNELS = %w[Channel::Whatsapp Channel::WhatsappWeb Channel::TwilioSms Channel::Sms].freeze

  class Blocked < StandardError; end

  class << self
    def issue(attributes)
      payload = attributes.to_h.deep_stringify_keys.merge('version' => 1, 'expires_at' => 24.hours.from_now.to_i)
      { 'token' => verifier.generate(payload, purpose: PURPOSE) }
    end

    def verified(policy)
      return unless policy.is_a?(Hash)

      token = policy.with_indifferent_access[:token]
      payload = verifier.verified(token, purpose: PURPOSE) if token.is_a?(String)
      return unless payload.is_a?(Hash) && payload['version'] == 1 && payload['expires_at'].to_i > Time.current.to_i
      return unless payload['mode'] == 'live' && payload['run_id'].to_s.match?(/\A[0-9a-f-]{36}\z/)

      payload.with_indifferent_access
    rescue ArgumentError, TypeError, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def with(policy)
      previous = Current.playground_run_policy
      Current.playground_run_policy = policy&.deep_dup
      yield
    ensure
      Current.playground_run_policy = previous
    end

    def for_record(record)
      return unless record

      %i[metadata additional_attributes custom_attributes execution_state].each do |field|
        next unless record.respond_to?(field)

        attributes = record.public_send(field)
        next unless attributes.is_a?(Hash)

        attributes = attributes.with_indifferent_access
        return attributes[ATTRIBUTE_KEY].nil? ? {} : attributes[ATTRIBUTE_KEY] if attributes.key?(ATTRIBUTE_KEY)
      end
      nil
    end

    def for_execution(record)
      scoped_policy(for_record(record))
    end

    def for_run(policy)
      scoped_policy(policy)
    end

    def policy_for(conversation: nil, message: nil, reminder: nil)
      stored = [for_record(message), for_record(reminder)].find { |value| !value.nil? }
      policy = scoped_policy(stored)
      conversation_policy = for_record(conversation)
      return {} if !policy.nil? && !conversation_policy.nil? && policy != conversation_policy

      policy = conversation_policy if policy.nil?
      return policy unless policy.nil?
      return {} if test_source?(conversation) || test_source?(conversation&.contact)

      nil
    end

    def ensure!(conversation:, policy: nil, private_note: false)
      return true if private_note

      policy = policy_for(conversation: conversation) if policy.nil?
      policies = [policy, Current.playground_run_policy, for_record(conversation)].reject(&:nil?).uniq
      return true if policies.empty?
      raise Blocked, BLOCKED_MESSAGE unless policies.all? { |value| allowed?(value, conversation: conversation) }

      true
    end

    def allowed?(policy, conversation:)
      payload = verified(policy)
      return false unless payload && payload[:delivery_enabled] == true && conversation
      return false unless payload[:account_id].to_s == conversation.account_id.to_s
      return false unless payload[:conversation_id].to_s == conversation.id.to_s && payload[:caller_contact_id].to_s == conversation.contact_id.to_s
      return false unless payload[:inbox_id].to_s == conversation.inbox_id.to_s && PHONE_CHANNELS.include?(conversation.inbox.channel_type)
      return false unless AccountUser.find_by(account_id: conversation.account_id, user_id: payload[:user_id])&.administrator?
      return false unless valid_source?(payload, conversation)

      target = normalize_phone(payload[:delivery_target])
      return false if target.blank? || target != normalize_phone(conversation.contact&.phone_number)

      source = conversation.contact_inbox&.source_id.to_s.delete_prefix('whatsapp:')
      target == normalize_phone(source)
    end

    def normalize_phone(value)
      digits = value.to_s.gsub(/\D/, '')
      return unless digits.match?(/\A[1-9]\d{7,14}\z/)

      "+#{digits}"
    end

    def verifier
      Rails.application.message_verifier(PURPOSE)
    end

    def test_source?(record)
      record&.additional_attributes.to_h.key?('captain_playground_source')
    end

    def external_notification_blocked?(*actors)
      return true unless Current.playground_run_policy.nil?

      actors.compact.any? do |actor|
        !for_record(actor).nil? || (actor.respond_to?(:additional_attributes) && test_source?(actor))
      end
    end

    def valid_source?(payload, conversation)
      expected = payload.slice(:session_id, :account_id, :user_id, :assistant_id).stringify_keys
      [conversation, conversation.contact].all? do |record|
        record&.additional_attributes.to_h['captain_playground_source'] == expected
      end
    end

    private

    def scoped_policy(stored)
      inherited = Current.playground_run_policy
      return inherited if stored.nil?
      return {} unless inherited.nil? || inherited == stored

      stored
    end
  end
end
