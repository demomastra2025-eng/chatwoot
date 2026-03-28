class Captain::ContextFields
  FIELD_REFERENCE_REGEX = %r{\[([^\]]+)\]\(field://([^)]+)\)}
  SCOPES = %i[contact conversation].freeze
  CONTACT_STATE_ATTRIBUTES = %i[
    id name email phone_number identifier contact_type
    custom_attributes additional_attributes
  ].freeze
  CONVERSATION_STATE_ATTRIBUTES = %i[
    id display_id inbox_id contact_id status priority
    label_list custom_attributes additional_attributes
  ].freeze

  CONTACT_FIELD_DEFINITIONS = [
    { key: 'id', title: 'Contact ID', description: 'contact.id' },
    { key: 'name', title: 'Name', description: 'contact.name' },
    { key: 'email', title: 'Email', description: 'contact.email' },
    { key: 'phone_number', title: 'Phone Number', description: 'contact.phone_number' },
    { key: 'identifier', title: 'Identifier', description: 'contact.identifier' },
    { key: 'contact_type', title: 'Contact Type', description: 'contact.contact_type' }
  ].freeze

  CONVERSATION_FIELD_DEFINITIONS = [
    { key: 'id', title: 'Conversation Record ID', description: 'conversation.id' },
    { key: 'display_id', title: 'Conversation ID', description: 'conversation.display_id' },
    { key: 'inbox_id', title: 'Inbox ID', description: 'conversation.inbox_id' },
    { key: 'contact_id', title: 'Contact ID', description: 'conversation.contact_id' },
    { key: 'status', title: 'Status', description: 'conversation.status' },
    { key: 'priority', title: 'Priority', description: 'conversation.priority' },
    { key: 'label_list', title: 'Labels', description: 'conversation.label_list' }
  ].freeze

  ATTRIBUTE_MODELS = {
    'contact' => 'contact_attribute',
    'conversation' => 'conversation_attribute'
  }.freeze

  GROUP_NAMES = {
    'contact' => 'Contact',
    'contact_custom_attributes' => 'Contact Attributes',
    'conversation' => 'Conversation',
    'conversation_custom_attributes' => 'Conversation Attributes'
  }.freeze

  class << self
    def definitions_for(account)
      contact_fields + conversation_fields + custom_attribute_fields(account, 'contact') + custom_attribute_fields(account, 'conversation')
    end

    def field_ids_for(account)
      definitions_for(account).map { |field| field[:id] }
    end

    def allowed_definitions_for(assistant)
      definitions = definitions_for(assistant.account)
      access = normalized_access_for(assistant, definitions)

      definitions.select do |field|
        scope = field[:table_name].to_sym
        access.dig(scope, :enabled) && access.dig(scope, :field_ids)&.include?(field[:id])
      end
    end

    def allowed_field_ids_for(assistant)
      allowed_definitions_for(assistant).map { |field| field[:id] }
    end

    def normalized_access_for(assistant, definitions = definitions_for(assistant.account))
      available_ids_by_scope = definitions.group_by { |field| field[:table_name].to_sym }
                                        .transform_values { |fields| fields.map { |field| field[:id] } }
      raw_access = assistant.config&.with_indifferent_access&.dig(:context_access) || {}

      SCOPES.index_with do |scope|
        normalize_scope_access(raw_access[scope], available_ids_by_scope[scope] || [])
      end
    end

    def prompt_state_for(assistant:, runtime_state:)
      access = normalized_access_for(assistant)
      assistant_config = assistant.config&.with_indifferent_access || {}
      explicit_access_config = assistant_config.key?(:context_access)
      prompt_state = {}
      visible_fields = {}

      SCOPES.each do |scope|
        scope_access = access.fetch(scope)
        next unless scope_access[:enabled]

        scoped_prompt_state = build_scoped_prompt_state(
          scope: scope,
          raw_scope_state: runtime_state[scope],
          allowed_field_ids: scope_access[:field_ids],
          include_additional_attributes: !explicit_access_config
        )
        next if scoped_prompt_state.blank?

        prompt_state[scope] = scoped_prompt_state
        visible_fields[scope] = visible_core_field_keys(scope_access[:field_ids], scope)
      end

      prompt_state[:visible_fields] = visible_fields if visible_fields.present?
      prompt_state
    end

    def extract_field_ids_from_text(text)
      return [] if text.blank?

      text.scan(FIELD_REFERENCE_REGEX).map { |_label, field_id| normalize_field_id(field_id) }.uniq
    end

    def render_references(text, prompt_state:, allowed_fields:)
      return text if text.blank?

      allowed_fields_by_id = allowed_fields.index_by { |field| field[:id] }

      text.gsub(FIELD_REFERENCE_REGEX) do
        label = Regexp.last_match(1)
        field_id = normalize_field_id(Regexp.last_match(2))
        definition = allowed_fields_by_id[field_id]
        cleaned_label = clean_reference_label(label, definition)

        next cleaned_label if definition.blank?

        value = value_for(prompt_state, field_id)
        formatted_value = format_value(value)

        formatted_value.present? ? "#{cleaned_label} (#{field_id}: #{formatted_value})" : "#{cleaned_label} (#{field_id})"
      end
    end

    def value_for_field_id(prompt_state, field_id)
      value_for(prompt_state, normalize_field_id(field_id))
    end

    def core_field_keys(scope)
      field_definitions_for(scope).map { |definition| definition[:key] }
    end

    private

    def contact_fields
      build_field_group('contact', CONTACT_FIELD_DEFINITIONS)
    end

    def conversation_fields
      build_field_group('conversation', CONVERSATION_FIELD_DEFINITIONS)
    end

    def build_field_group(scope, definitions)
      definitions.map do |definition|
        {
          id: "#{scope}.#{definition[:key]}",
          title: definition[:title],
          description: definition[:description],
          group_name: GROUP_NAMES.fetch(scope),
          table_name: scope,
          field_type: 'field',
          field_key: definition[:key]
        }
      end
    end

    def custom_attribute_fields(account, scope)
      attribute_model = ATTRIBUTE_MODELS.fetch(scope)
      group_name = GROUP_NAMES.fetch("#{scope}_custom_attributes")

      account.custom_attribute_definitions
             .with_attribute_model(attribute_model)
             .map do |definition|
        {
          id: "#{scope}.custom_attributes.#{definition.attribute_key}",
          title: definition.attribute_display_name,
          description: "#{scope}.custom_attributes.#{definition.attribute_key}",
          group_name: group_name,
          table_name: scope,
          field_type: 'custom_attribute',
          field_key: definition.attribute_key
        }
      end
    end

    def field_definitions_for(scope)
      scope.to_s == 'contact' ? CONTACT_FIELD_DEFINITIONS : CONVERSATION_FIELD_DEFINITIONS
    end

    def normalize_scope_access(raw_scope, available_field_ids)
      raw_scope = raw_scope.to_h.with_indifferent_access if raw_scope.respond_to?(:to_h)
      raw_scope ||= {}

      field_ids =
        if raw_scope.key?(:field_ids)
          Array(raw_scope[:field_ids]).map { |field_id| normalize_field_id(field_id) }
        else
          available_field_ids
        end

      {
        enabled: raw_scope.key?(:enabled) ? ActiveModel::Type::Boolean.new.cast(raw_scope[:enabled]) : true,
        field_ids: field_ids & available_field_ids
      }
    end

    def build_scoped_prompt_state(scope:, raw_scope_state:, allowed_field_ids:, include_additional_attributes: false)
      return {} if raw_scope_state.blank? || allowed_field_ids.blank?

      scope_state = raw_scope_state.with_indifferent_access
      prompt_state = {}

      allowed_field_ids.each do |field_id|
        _, *path = field_id.split('.')
        next if path.blank?

        case path.first
        when 'custom_attributes'
          add_selected_custom_attribute(prompt_state, scope_state, path.last)
        when 'additional_attributes'
          # Additional attributes remain available to tools in the raw runtime state,
          # but are intentionally excluded from the prompt-facing field whitelist.
          next
        else
          prompt_state[path.first] = scope_state[path.first]
        end
      end

      if include_additional_attributes && scope_state[:additional_attributes].is_a?(Hash)
        prompt_state[:additional_attributes] = scope_state[:additional_attributes]
      end

      prompt_state
    end

    def add_selected_custom_attribute(prompt_state, scope_state, attribute_key)
      custom_attributes = scope_state[:custom_attributes]
      prompt_state[:custom_attributes] ||= {}

      if custom_attributes.is_a?(Hash)
        custom_attributes = custom_attributes.with_indifferent_access
        prompt_state[:custom_attributes][attribute_key] = custom_attributes[attribute_key]
      else
        prompt_state[:custom_attributes][attribute_key] = nil
      end
    end

    def visible_core_field_keys(allowed_field_ids, scope)
      allowed_field_ids
        .filter_map do |field_id|
          _, *path = field_id.split('.')
          next unless path.length == 1

          path.first
        end
        .uniq
        .select { |field_key| core_field_keys(scope).include?(field_key) }
    end

    def value_for(prompt_state, field_id)
      scope, *path = field_id.split('.')
      scoped_state = prompt_state&.with_indifferent_access&.dig(scope)
      return if scoped_state.blank?

      path.reduce(scoped_state.with_indifferent_access) do |memo, key|
        break unless memo.respond_to?(:with_indifferent_access)

        memo.with_indifferent_access[key]
      end
    end

    def format_value(value)
      case value
      when nil
        nil
      when Array
        value.join(', ')
      when Hash
        JSON.generate(value)
      else
        value.to_s.presence
      end
    rescue JSON::GeneratorError
      value.to_s.presence
    end

    def clean_reference_label(label, definition)
      sanitized_label = label.to_s.sub(/\A\$\s*/, '').squish
      sanitized_label.presence || definition&.dig(:title) || 'Field'
    end

    def normalize_field_id(field_id)
      field_id.to_s.gsub(/\\(.)/, '\1')
    end
  end
end
