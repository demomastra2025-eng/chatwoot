# frozen_string_literal: true

class Captain::Tools::Account::UpdateInboxSettingsService < Captain::Tools::Account::BaseAccountTool
  def self.name
    'update_inbox_settings'
  end

  description 'Update account inbox details and the workspace auto-assignment switch'
  param :inbox_id, type: :number, desc: 'Account inbox ID', required: true
  param :name, type: :string, desc: 'Optional inbox display name', required: false
  param :timezone, type: :string, desc: 'Optional TZInfo timezone identifier, for example Asia/Almaty', required: false
  param :enable_auto_assignment, type: :boolean, desc: 'Optional auto-assignment toggle', required: false
  param :working_hours_enabled, type: :boolean, desc: 'Optional working-hours toggle', required: false
  param :out_of_office_message, type: :string, desc: 'Optional out-of-office message', required: false
  param :allow_messages_after_resolved, type: :boolean, desc: 'Optional setting for messages after resolved conversations', required: false

  def execute(inbox_id:, **kwargs)
    ensure_account_administrator!

    inbox = account.inboxes.active.find(inbox_id)
    attributes = inbox_update_attributes(kwargs)
    workspace_assignment = kwargs.key?(:enable_auto_assignment)
    raise ArgumentError, 'No supported inbox settings were provided' if attributes.blank? && !workspace_assignment

    update_settings!(inbox, attributes, kwargs)

    formatted_payload(
      action: 'update_inbox_settings',
      inbox: inbox_payload(inbox.reload),
      updated_fields: attributes.keys.map(&:to_s) + (workspace_assignment ? ['enable_auto_assignment'] : [])
    )
  rescue StandardError => e
    tool_failure(e)
  end

  def active?
    account_administrator?
  end

  private

  def update_settings!(inbox, attributes, kwargs)
    ActiveRecord::Base.transaction do
      inbox.update!(attributes) if attributes.present?
      account.update!(conversation_auto_assignment_enabled: cast_boolean(kwargs[:enable_auto_assignment])) if kwargs.key?(:enable_auto_assignment)
    end
  end

  def inbox_update_attributes(kwargs)
    attributes = {}
    assign_string(attributes, kwargs, :name)
    assign_string(attributes, kwargs, :timezone)
    assign_string(attributes, kwargs, :out_of_office_message, allow_blank: true)
    assign_boolean(attributes, kwargs, :allow_messages_after_resolved)
    attributes
  end

  def assign_string(attributes, kwargs, key, allow_blank: false)
    return unless kwargs.key?(key)

    value = kwargs[key].to_s
    return if value.blank? && !allow_blank

    attributes[key] = value
  end

  def assign_boolean(attributes, kwargs, key)
    return unless kwargs.key?(key)

    attributes[key] = cast_boolean(kwargs[key])
  end

  def inbox_payload(inbox)
    {
      id: inbox.id,
      name: inbox.name,
      channel_type: inbox.display_channel_type,
      timezone: inbox.timezone,
      enable_auto_assignment: account.conversation_auto_assignment_enabled?,
      working_hours_enabled: account.workspace_working_hours_configured?,
      out_of_office_message: inbox.out_of_office_message,
      allow_messages_after_resolved: inbox.allow_messages_after_resolved
    }.compact
  end
end
