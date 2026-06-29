module LeadForms
  class WidgetSyncService
    attr_reader :account

    def initialize(account:)
      @account = account
    end

    def perform
      account.inboxes.includes(:channel).where(channel_type: 'Channel::WebWidget').find_each do |inbox|
        sync_inbox!(inbox)
      end
    end

    private

    def sync_inbox!(inbox)
      channel = inbox.channel
      return if channel.blank?

      lead_form = account.lead_forms.find_or_initialize_by(
        source_kind: 'widget',
        external_ref: "inbox:#{inbox.id}"
      )
      field_schema = widget_field_schema(channel)
      sync_channel_options!(channel, field_schema)
      lead_form.assign_attributes(
        inbox: inbox,
        name: lead_form.name.presence || "Widget form · #{inbox.name}",
        description: 'Website widget pre-chat form mirrored into lead intake settings.',
        status: channel.pre_chat_form_enabled? ? 'active' : 'paused',
        field_schema: field_schema,
        settings: widget_settings(inbox, channel)
      )
      lead_form.save!
    end

    def widget_field_schema(channel)
      options = channel.pre_chat_form_options.to_h.with_indifferent_access
      fields = Array(options[:pre_chat_fields]).map do |field|
        field.to_h.slice('name', 'label', 'type', 'required', 'enabled', 'placeholder', 'field_type').compact
      end
      ensure_required_phone_field(fields)
    end

    def ensure_required_phone_field(fields)
      phone_field = fields.find { |field| LeadForm::PHONE_FIELD_NAMES.include?(field['name'].to_s) }
      if phone_field.present?
        phone_field['enabled'] = true
        phone_field['required'] = true
        phone_field['type'] = 'tel' if phone_field['type'].blank? || phone_field['type'] == 'text'
        return fields
      end

      fields.unshift(
        'name' => 'phoneNumber',
        'label' => 'Phone Number',
        'type' => 'tel',
        'required' => true,
        'enabled' => true,
        'placeholder' => 'Please enter your phone number',
        'field_type' => 'standard'
      )
    end

    def sync_channel_options!(channel, fields)
      options = channel.pre_chat_form_options.to_h.deep_stringify_keys
      return if Array(options['pre_chat_fields']) == fields

      channel.update!(pre_chat_form_options: options.merge('pre_chat_fields' => fields))
    end

    def widget_settings(inbox, channel)
      options = channel.pre_chat_form_options.to_h.with_indifferent_access
      {
        inbox_id: inbox.id,
        website_url: channel.website_url,
        pre_chat_form_enabled: channel.pre_chat_form_enabled?,
        pre_chat_message: options[:pre_chat_message],
        pre_chat_fields: Array(options[:pre_chat_fields]),
        managed_in: 'settings/inboxes/pre_chat_form'
      }
    end
  end
end
