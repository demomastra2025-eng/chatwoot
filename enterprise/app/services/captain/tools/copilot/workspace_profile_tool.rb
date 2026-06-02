# frozen_string_literal: true

require Rails.root.join('enterprise/lib/onelink/mcp/access_policy').to_s

class Captain::Tools::Copilot::WorkspaceProfileTool < Captain::Tools::Copilot::BaseAccountTool
  ACCOUNT_ATTRIBUTE_KEYS = %i[name locale domain support_email].freeze
  CUSTOM_ATTRIBUTE_KEYS = %i[industry company_size timezone].freeze
  SETTING_KEYS = %i[
    reporting_timezone
    auto_resolve_after
    auto_resolve_message
    auto_resolve_ignore_waiting
    auto_resolve_label
    scheduling_contact_required
    scheduling_company_enabled
    default_appointment_touch_plan_id
    default_deal_touch_plan_id
    default_task_touch_plan_id
  ].freeze
  UPDATE_PARAM_KEYS = (ACCOUNT_ATTRIBUTE_KEYS + CUSTOM_ATTRIBUTE_KEYS + SETTING_KEYS).map(&:to_s).freeze
  TOUCH_PLAN_SETTING_ENTITY_KINDS = {
    default_appointment_touch_plan_id: 'appointment',
    default_deal_touch_plan_id: 'deal',
    default_task_touch_plan_id: 'task'
  }.freeze
  BOOLEAN_SETTING_KEYS = %i[
    auto_resolve_ignore_waiting
    scheduling_contact_required
    scheduling_company_enabled
  ].freeze
  INTEGER_SETTING_KEYS = %i[
    auto_resolve_after
    default_appointment_touch_plan_id
    default_deal_touch_plan_id
    default_task_touch_plan_id
  ].freeze
  def active?
    account_administrator?
  end

  private

  def workspace_profile_payload
    {
      id: account.id,
      name: account.name,
      locale: account.locale,
      domain: account.domain,
      support_email: account.support_email,
      configured_support_email: account.attributes['support_email'],
      status: account.status,
      logo_url: account.logo_url,
      custom_attributes: workspace_custom_attributes,
      settings: workspace_settings,
      mcp_access: workspace_mcp_access_summary,
      available_locales: Account.locales.keys,
      counts: workspace_counts
    }.compact
  end

  def workspace_custom_attributes
    custom_attributes = account.custom_attributes || {}
    CUSTOM_ATTRIBUTE_KEYS.index_with { |key| custom_attributes[key.to_s] }.compact
  end

  def workspace_settings
    settings = account.settings || {}
    SETTING_KEYS.index_with { |key| settings[key.to_s] }.compact
  end

  def workspace_mcp_access_summary
    access = Onelink::Mcp::AccessPolicy.normalize(account.mcp_access)
    {
      enabled: access['enabled'],
      max_risk_level: access['max_risk_level'],
      sources: access['sources'],
      require_confirmation_for_mutations: access['require_confirmation_for_mutations']
    }
  end

  def workspace_counts
    {
      users: account.account_users.count,
      teams: account.teams.count,
      inboxes: account.inboxes.count,
      assistants: Captain::Assistant.for_account(account.id).count
    }
  end

  def editable_workspace_fields
    {
      account: ACCOUNT_ATTRIBUTE_KEYS,
      custom_attributes: CUSTOM_ATTRIBUTE_KEYS,
      settings: SETTING_KEYS
    }
  end

  def workspace_profile_update_attributes(raw_kwargs)
    kwargs = raw_kwargs.to_h.with_indifferent_access
    unknown_keys = kwargs.keys.map(&:to_s) - UPDATE_PARAM_KEYS
    raise ArgumentError, "Unsupported workspace profile fields: #{unknown_keys.join(', ')}" if unknown_keys.present?

    {
      account: account_attributes_from(kwargs),
      custom_attributes: custom_attributes_from(kwargs),
      settings: settings_from(kwargs)
    }
  end

  def account_attributes_from(kwargs)
    ACCOUNT_ATTRIBUTE_KEYS.each_with_object({}) do |key, attributes|
      next unless kwargs.key?(key)

      attributes[key] = case key
                        when :locale
                          normalize_locale(kwargs[key])
                        when :name
                          normalize_required_string(kwargs[key], field_name: 'name')
                        else
                          normalize_optional_string(kwargs[key])
                        end
    end
  end

  def custom_attributes_from(kwargs)
    CUSTOM_ATTRIBUTE_KEYS.each_with_object({}) do |key, attributes|
      next unless kwargs.key?(key)

      attributes[key.to_s] = normalize_optional_string(kwargs[key])
    end
  end

  def settings_from(kwargs)
    SETTING_KEYS.each_with_object({}) do |key, settings|
      next unless kwargs.key?(key)

      settings[key.to_s] = setting_value_for(key, kwargs[key])
    end
  end

  def setting_value_for(key, value)
    return cast_boolean(value) if BOOLEAN_SETTING_KEYS.include?(key)
    return normalize_touch_plan_id(value, key: key) if TOUCH_PLAN_SETTING_ENTITY_KINDS.key?(key)
    return normalize_optional_integer(value, field_name: key.to_s) if INTEGER_SETTING_KEYS.include?(key)

    normalize_optional_string(value)
  end

  def normalize_locale(value)
    locale = normalize_required_string(value, field_name: 'locale')
    return locale if Account.locales.key?(locale)

    raise ArgumentError, "locale must be one of: #{Account.locales.keys.join(', ')}"
  end

  def normalize_required_string(value, field_name:)
    text = value.to_s.strip
    raise ArgumentError, "#{field_name} cannot be blank" if text.blank?

    text
  end

  def normalize_optional_string(value)
    value&.to_s&.strip
  end

  def normalize_optional_integer(value, field_name:)
    return nil if value.blank?

    Integer(value)
  rescue ArgumentError, TypeError
    raise ArgumentError, "#{field_name} must be an integer"
  end

  def normalize_touch_plan_id(value, key:)
    touch_plan_id = normalize_optional_integer(value, field_name: key.to_s)
    return nil if touch_plan_id.blank?

    touch_plan = account.reminder_groups.kept.find(touch_plan_id)
    entity_kind = TOUCH_PLAN_SETTING_ENTITY_KINDS.fetch(key)
    return touch_plan_id if touch_plan.entity_kind_supported?(entity_kind)

    raise ArgumentError, "#{key} must reference a touch plan that supports #{entity_kind}"
  end

  def supported_field_provided?(updates)
    updates.values.any?(&:present?)
  end

  def apply_workspace_profile_updates!(updates)
    account.assign_attributes(updates[:account]) if updates[:account].present?

    account.custom_attributes = merged_custom_attributes(updates[:custom_attributes]) if updates[:custom_attributes].present?

    account.settings = (account.settings || {}).merge(updates[:settings]) if updates[:settings].present?

    account.save!
  end

  def updated_workspace_fields(updates)
    updates.flat_map do |group, attributes|
      attributes.keys.map { |field| "#{group}.#{field}" }
    end
  end

  def merged_custom_attributes(custom_attributes)
    (account.custom_attributes || {}).merge(custom_attributes)
  end
end
