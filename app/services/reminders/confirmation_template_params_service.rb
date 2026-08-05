# frozen_string_literal: true

class Reminders::ConfirmationTemplateParamsService
  def initialize(reminder:, confirmation_request:)
    @reminder = reminder
    @confirmation_request = confirmation_request
  end

  def perform(template_params)
    params = template_params.to_h.deep_stringify_keys.deep_dup
    template = selected_template!(params)
    validate_confirmation_button!
    inject_confirmation_payload(params, Array(template[:buttons]).length)
  end

  private

  attr_reader :reminder, :confirmation_request

  def selected_template!(params)
    template = template_catalog.find_template(params)
    return template if template.present?

    raise ArgumentError, 'Approved WhatsApp template was not found for appointment confirmation'
  end

  def validate_confirmation_button!
    validator = Reminders::ConfirmationTemplateValidator.new(
      account: reminder.account,
      inbox: reminder.target_inbox,
      template_params: reminder.template_params,
      button_index: reminder.response_button_index
    )
    return if validator.valid?

    raise ArgumentError, 'Appointment confirmation requires exactly one WhatsApp quick-reply button'
  end

  def inject_confirmation_payload(params, button_count)
    processed_params = params['processed_params'].to_h.deep_stringify_keys
    buttons = normalized_buttons(processed_params['buttons'], button_count)
    buttons[reminder.response_button_index] = {
      'type' => 'quick_reply',
      'parameter' => confirmation_payload
    }
    processed_params['buttons'] = buttons
    params.merge('processed_params' => processed_params)
  end

  def normalized_buttons(raw_buttons, button_count)
    buttons = Array(raw_buttons).map { |item| item.respond_to?(:to_h) ? item.to_h.deep_stringify_keys : {} }
    buttons.fill({}, buttons.length...button_count)
  end

  def template_catalog
    @template_catalog ||= Outbound::ChannelTemplateCatalog.new(inbox: reminder.target_inbox)
  end

  def confirmation_payload
    "confirmation:#{confirmation_request.token}:confirmed"
  end
end
