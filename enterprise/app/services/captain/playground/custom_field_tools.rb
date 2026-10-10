module Captain::Playground::CustomFieldTools
  private

  def field_catalog(kind, context: nil)
    definitions = Array(@data['custom_fields']).select { |item| item['entity_kind'] == kind && item['active'] != false }.map do |item|
      Crm::FieldDefinition.new(item.slice('entity_kind', 'key', 'label', 'field_type', 'required', 'default_value', 'description', 'options', 'rules', 'active', 'position'))
    end
    Crm::FieldCatalog.new(account: @session.account, entity_kind: kind, context: context, definitions: definitions)
  end

  def custom_field_catalog
    kind = @tool_id.delete_prefix('list_').delete_suffix('_custom_fields')
    fields = Captain::Tools::CrmCustomFieldCatalog.new(account: @session.account, entity_kind: kind,
                                                     catalog: field_catalog(kind, context: @args['context'])).fields
    { entity_kind: kind, fields: fields, total_count: fields.size, simulated: true }
  end

  def custom_attributes_for(kind, record: nil, context: nil)
    incoming = @args['custom_attributes']
    incoming = JSON.parse(incoming) if incoming.is_a?(String)
    raise ArgumentError, 'Custom attributes must be an object' unless incoming.nil? || incoming.is_a?(Hash)

    field_catalog(kind, context: context).resolve_custom_attributes(current_attributes: record.to_h['custom_attributes'],
                                                                   incoming_attributes: incoming, apply_defaults: record.nil?)
  rescue JSON::ParserError
    raise ArgumentError, 'Custom attributes must be valid JSON'
  end
end
