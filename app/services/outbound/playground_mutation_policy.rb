require 'digest'

# Only a server-issued exact action approval can authorize a new provider write.
# Legacy inflight commands retain their readback/reconciliation path; this gate
# never grants a new write from a legacy Live delivery token.
class Outbound::PlaygroundMutationPolicy
  OPERATIONS = { 'create_appointment' => 'create_reception', 'update_appointment' => 'move_reception',
                 'cancel_appointment' => 'remove_reception' }.freeze

  class << self
    def for_command(policy, snapshot)
      return policy if policy.nil?

      payload = Outbound::PlaygroundDeliveryPolicy.verified(policy)
      return policy unless payload&.dig(:version) == 2
      raise Outbound::PlaygroundDeliveryPolicy::Blocked, 'Exact Playground action approval is required' unless approved?(payload)
      raise Outbound::PlaygroundDeliveryPolicy::Blocked, 'Provider command differs from the approved action' unless command_matches?(payload, snapshot)

      Outbound::PlaygroundDeliveryPolicy.issue(payload.to_h.merge(provider_binding: binding_for(snapshot)))
    end

    def allowed_command?(command, policy)
      return true if policy.nil?

      payload = Outbound::PlaygroundDeliveryPolicy.verified(policy)
      payload&.dig(:version) == 2 && approved?(payload) && command_matches?(payload, command.request_snapshot) &&
        payload[:provider_binding].to_h.deep_stringify_keys == binding_for(command.request_snapshot)
    end

    def authorized_action?(policy)
      payload = Outbound::PlaygroundDeliveryPolicy.verified(policy)
      payload&.dig(:version) == 2 && approved?(payload)
    end

    private

    def approved?(payload)
      return false unless defined?(Captain::Playground::SessionStore)

      account = Account.find_by(id: payload[:account_id])
      user = User.find_by(id: payload[:user_id])
      assistant = Captain::Assistant.find_by(id: payload[:assistant_id], account_id: account&.id)
      return false unless account && user && assistant && account.account_users.exists?(user_id: user.id)
      return false unless Captain::Playground::ToolSelection.include?(assistant, payload[:tool])
      return false unless operator_authorized?(account, user, assistant, payload)

      store = Captain::Playground::SessionStore.new(account: account, user: user, assistant: assistant)
      permissions = store.permissions(session_id: payload[:session_id])
      return false unless permissions['read'] == true && permissions['write'] == true && permissions['generation'] == payload[:generation]

      session = store.read(session_id: payload[:session_id])
      action = Array(session&.dig('action_previews')).find { |item| item['id'] == payload[:action_id] }
      action && %w[executing completed].include?(action['status']) && action['digest'] == payload[:action_digest] &&
        action['tool'] == payload[:tool] && action['arguments'] == payload[:arguments].to_h.deep_stringify_keys &&
        action['target'] == payload[:target].to_h.deep_stringify_keys
    rescue Captain::Playground::SessionStore::Stale, ArgumentError
      false
    end

    def operator_authorized?(account, user, assistant, payload)
      definition = Captain::ToolRegistry.definition_for(payload[:tool])
      return false unless definition && Captain::ToolPolicy.execution_allowed?(
        definition.to_h, assistant: assistant, scope_name: Captain::ToolAccess::SCOPE_ASSISTANT, user: user
      )

      context = { user: user, account: account, account_user: account.account_users.find_by(user_id: user.id) }
      policies = { 'Contact' => [Contact, ContactPolicy], 'Conversation' => [Conversation, ConversationPolicy],
                   'Crm::Deal' => [Crm::Deal, Crm::DealPolicy], 'Crm::Task' => [Crm::Task, Crm::TaskPolicy] }
      payload[:target].to_h.values.all? do |target|
        target = target.to_h.with_indifferent_access
        record_class, policy_class = policies[target[:type]]
        next true unless record_class

        record = record_class.find_by(id: target[:id], account_id: account.id)
        record && policy_class.new(context, record).update?
      end
    end

    def command_matches?(payload, snapshot)
      snapshot = snapshot.to_h.with_indifferent_access
      return false unless snapshot[:account_id].to_s == payload[:account_id].to_s && OPERATIONS[payload[:tool]] == snapshot[:operation]
      return false unless snapshot.dig(:actor, :type) == 'User' && snapshot.dig(:actor, :id).to_s == payload[:user_id].to_s

      arguments = payload[:arguments].to_h.with_indifferent_access
      target = payload[:target].to_h.with_indifferent_access
      appointment = target.dig(:appointment_id, :appointment).to_h.with_indifferent_access
      expected_id = target.dig(:appointment_id, :id)
      return false if expected_id && expected_id.to_s != snapshot[:appointment_id].to_s
      return false unless patient_matches?(target, appointment, snapshot)

      %w[resource_id service_id].each do |key|
        expected = arguments[key] || appointment[key]
        return false if expected && expected.to_s != snapshot.dig(:reception, key).to_s
      end
      cabinet = arguments[:custom_attributes].to_h.with_indifferent_access[:medelement_cabinet_code] || appointment[:cabinet_code]
      return false if cabinet.present? && cabinet.to_s != snapshot[:company_cabinet_code].to_s

      %w[starts_at ends_at].each do |key|
        expected = arguments[key] || appointment[key]
        next unless expected

        actual = snapshot.dig(:reception, "destination_#{key}")
        return false unless Time.iso8601(expected.to_s) == Time.iso8601(actual.to_s)
      end
      duration = arguments[:duration_min]
      return true unless duration

      starts = Time.iso8601(snapshot.dig(:reception, :destination_starts_at).to_s)
      ends = Time.iso8601(snapshot.dig(:reception, :destination_ends_at).to_s)
      (ends.to_r - starts.to_r) == Rational(duration.to_s) * 60
    rescue ArgumentError
      false
    end

    def patient_matches?(target, appointment, snapshot)
      policy = Integrations::Medelement::AppointmentPatientIdentity
      expected_id = target.dig(:patient, :id) || appointment[:patient_contact_id]
      actual_id = snapshot[policy::BINDING_KEY] || snapshot[:contact_id]
      return false unless expected_id && expected_id.to_s == actual_id.to_s

      actual = snapshot[policy::SNAPSHOT_KEY].to_h.with_indifferent_access
      return false unless actual[:fields].is_a?(Hash)
      return actual.deep_stringify_keys == appointment[:patient_identity].to_h.deep_stringify_keys if appointment[:patient_identity]

      identity = target.dig(:patient, :clinical_identity).to_h.with_indifferent_access
      return false if identity[:iin].blank?

      expected = policy::NAME_KEYS.index_with { |key| identity[key] }
      expected.merge!('identifier' => identity[:iin], 'birth_date' => identity[:birth_date])
      expected.all? do |key, value|
        policy.normalize("client_#{key}", value) == policy.normalize("client_#{key}", actual[:fields]["client_#{key}"])
      end
    end

    def binding_for(snapshot)
      { 'fingerprint' => Integrations::Medelement::ProviderCommands::RequestSnapshotBuilder.fingerprint(snapshot.to_h.deep_stringify_keys),
        'operation' => snapshot.to_h.with_indifferent_access[:operation],
        'account_id' => snapshot.to_h.with_indifferent_access[:account_id],
        'appointment_id' => snapshot.to_h.with_indifferent_access[:appointment_id] }
    end
  end
end
