class AutomationRules::AppointmentCreatedNotificationHold
  HOLD_KEY = 'appointment_created_notification_hold'.freeze
  DONE_KEY = 'appointment_created_notification_actions'.freeze
  COMPLETE_KEY = 'appointment_created_notification_complete'.freeze
  NOTIFYING_ACTIONS = %w[create_touch send_webhook_event apply_touch_plan].freeze

  def self.required?(appointment, performed_by:)
    return false if appointment.resource&.custom_attributes.to_h['medelement_specialist_code'].blank?
    return false if appointment.source == 'medelement' || appointment.contact.blank?
    return false if appointment.custom_attributes.to_h[Integrations::Medelement::AppointmentProviderStatus::ATTRIBUTE_KEY].blank?
    return false unless performed_by.is_a?(User) || (defined?(Captain::Assistant) && performed_by.is_a?(Captain::Assistant))
    return false if defined?(Captain::Assistant) && performed_by.is_a?(Captain::Assistant) && performed_by.account_id != appointment.account_id

    hook = appointment.account.hooks.enabled.find_by(app_id: 'medelement')
    hook&.feature_allowed? && Integrations::Medelement::Configuration.new(hook: hook).write_enabled?
  end

  def self.notifying_actions(rule)
    Array(rule.actions).select { |action| NOTIFYING_ACTIONS.include?(action.with_indifferent_access[:action_name]) }
  end

  def self.other_actions(rule)
    Array(rule.actions).reject { |action| NOTIFYING_ACTIONS.include?(action.with_indifferent_access[:action_name]) }
  end

  def self.record!(appointment, rules)
    appointment.with_lock do
      next if appointment.custom_attributes.to_h[HOLD_KEY].present?

      attributes = appointment.custom_attributes.to_h.merge(HOLD_KEY => { 'rule_ids' => rules.map(&:id) })
      appointment.update_columns(custom_attributes: attributes)
    end
  end

  def initialize(command:)
    @command = command
  end

  def perform
    return unless @command.create_reception? && @command.succeeded?

    ApplicationRecord.connection_pool.with_connection do |connection|
      key = Digest::SHA256.hexdigest("appointment-created-notification:#{@command.appointment_id}:#{@command.id}").first(16).to_i(16) % ((2**63) - 1)
      connection.execute("SELECT pg_advisory_lock(#{key})")
      begin
        release_actions
      ensure
        connection.execute("SELECT pg_advisory_unlock(#{key})")
      end
    end
  end

  private

  def release_actions
    @command.reload
    appointment = @command.appointment&.reload
    return unless appointment

    hold = appointment.custom_attributes.to_h[HOLD_KEY].to_h
    return if hold.blank? || @command.execution_state.to_h[COMPLETE_KEY]
    if appointment.status.in?(%w[cancelled completed no_show])
      mark_complete!
      return
    end
    return unless expected_create?(appointment)

    Array(hold['rule_ids']).each do |rule_id|
      rule = AutomationRule.find_by(id: rule_id, account_id: appointment.account_id, event_name: 'appointment_created', active: true)
      next unless rule

      self.class.notifying_actions(rule).each_with_index do |action, index|
        action_key = "#{rule.id}:#{action.with_indifferent_access[:action_id].presence || index}"
        next if @command.execution_state.to_h.fetch(DONE_KEY, []).include?(action_key)

        notification_key = "appointment-created:#{appointment.id}:#{@command.id}:#{action_key}"
        action = action.with_indifferent_access.merge(action_id: action_key)
        AutomationRules::AppointmentActionService.new(
          rule, appointment.account, appointment, delayed_notification: true, notification_key: notification_key
        ).perform(actions: [action], raise_errors: true)
        @command.with_lock do
          state = @command.execution_state.to_h
          @command.update!(execution_state: state.merge(DONE_KEY => (Array(state[DONE_KEY]) + [action_key]).uniq))
        end
      end
    end
    mark_complete!
  end

  def mark_complete!
    @command.with_lock do
      @command.update!(execution_state: @command.execution_state.to_h.merge(COMPLETE_KEY => true))
    end
  end

  def expected_create?(appointment)
    status = Integrations::Medelement::AppointmentProviderStatus
    appointment.status.in?(%w[scheduled confirmed]) &&
      appointment.custom_attributes.to_h[status::COMMAND_ID_KEY].to_s == @command.id.to_s &&
      @command.account_id == appointment.account_id && @command.succeeded?
  end
end
