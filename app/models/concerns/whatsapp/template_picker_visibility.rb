# Lets admins hide individual WhatsApp templates from the conversation reply
# picker. The flag lives on each cached template hash as
# 'visible_in_conversation_picker' (absent means visible) and survives provider
# template syncs, so no migration is needed.
module Whatsapp::TemplatePickerVisibility
  extend ActiveSupport::Concern

  def update_message_templates_cache!(templates)
    updated = with_lock do
      persist_message_templates_cache!(preserve_template_picker_visibility(templates))
    end
    inbox&.update_account_cache if updated
    updated
  end

  def update_template_picker_visibility!(template_name, visible:)
    updated = with_lock do
      templates = Array(message_templates).deep_dup
      matching_templates = templates.select { |template| template.is_a?(Hash) && template['name'] == template_name }
      next false if matching_templates.empty?

      matching_templates.each { |template| template['visible_in_conversation_picker'] = visible }
      # Not a provider sync: keep message_templates_last_updated, which the
      # templates page shows as the last sync and the sync scheduler reads.
      persist_message_templates_cache!(templates, synced: false)
    end
    inbox&.update_account_cache if updated
    updated
  end

  private

  def preserve_template_picker_visibility(templates)
    visibility_by_name = Array(message_templates).filter_map do |template|
      next unless template.is_a?(Hash) && template.key?('visible_in_conversation_picker')

      [template['name'], template['visible_in_conversation_picker']]
    end.to_h

    Array(templates).map do |template|
      next template unless template.is_a?(Hash) && visibility_by_name.key?(template['name'])

      template.merge('visible_in_conversation_picker' => visibility_by_name[template['name']])
    end
  end

  def persist_message_templates_cache!(templates, synced: true)
    # Provider template sync already validated the upstream payload. Avoid running
    # provider validations again while updating the local cache.
    attributes = { message_templates: templates }
    attributes[:message_templates_last_updated] = Time.current.utc if synced
    update_columns(attributes) # rubocop:disable Rails/SkipsModelValidations
  end
end
