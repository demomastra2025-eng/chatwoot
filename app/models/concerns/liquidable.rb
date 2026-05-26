module Liquidable
  extend ActiveSupport::Concern

  included do
    before_create :process_liquid_in_content
    before_create :process_liquid_in_template_params
  end

  private

  def message_drops
    drops = {
      'contact' => ContactDrop.new(conversation.contact),
      'agent' => UserDrop.new(sender || conversation.assignee),
      'conversation' => ConversationDrop.new(conversation),
      'inbox' => InboxDrop.new(inbox),
      'account' => AccountDrop.new(conversation.account)
    }

    if defined?(Captain::ContextFields)
      account = conversation.account
      drops['deal'] = build_runtime_state_drop(
        Captain::ContextFields.deal_state_for(account: account, conversation: conversation)
      )
      drops['task'] = build_runtime_state_drop(
        Captain::ContextFields.task_state_for(account: account, conversation: conversation)
      )
      drops['appointment'] = build_runtime_state_drop(
        Captain::ContextFields.appointment_state_for(account: account, conversation: conversation)
      )
    end

    drops.compact
  end

  def liquid_processable_message?
    content.present? && (message_type == 'outgoing' || message_type == 'template')
  end

  def process_liquid_in_content
    return unless liquid_processable_message?

    self.content = process_liquid_string(modified_liquid_content)
  rescue StandardError
    # If there is an error in the liquid syntax, we don't want to process it
  end

  def modified_liquid_content
    # This regex is used to match the code blocks in the content
    # We don't want to process liquid in code blocks
    content.gsub(/`(.*?)`/m, '{% raw %}`\\1`{% endraw %}')
  end

  def process_liquid_in_template_params
    return unless template_params_present? && liquid_processable_template_params?

    processed_params = process_liquid_in_hash(template_params_data['processed_params'])

    # Update the additional_attributes with processed template_params
    self.additional_attributes = additional_attributes.merge(
      'template_params' => template_params_data.merge('processed_params' => processed_params)
    )
  rescue Liquid::Error
    # If there is an error in the liquid syntax, we don't want to process it
  end

  def template_params_present?
    additional_attributes&.dig('template_params', 'processed_params').present?
  end

  def liquid_processable_template_params?
    message_type == 'outgoing' || message_type == 'template'
  end

  def template_params_data
    additional_attributes['template_params']
  end

  def process_liquid_in_hash(hash)
    return hash unless hash.is_a?(Hash)

    hash.transform_values { |value| process_liquid_value(value) }
  end

  def process_liquid_value(value)
    case value
    when String
      process_liquid_string(value)
    when Hash
      process_liquid_in_hash(value)
    when Array
      process_liquid_array(value)
    else
      value
    end
  end

  def process_liquid_array(array)
    array.map { |item| process_liquid_value(item) }
  end

  def process_liquid_string(string)
    return string if string.blank?

    string = field_reference_renderer.render(string)
    template = Liquid::Template.parse(string)
    template.render(message_drops)
  rescue Liquid::Error
    string
  end

  def build_runtime_state_drop(state)
    return if state.blank?

    RuntimeStateDrop.new(state)
  end

  def field_reference_renderer
    @field_reference_renderer ||= FieldReferences::RendererService.new(message: self)
  end
end
