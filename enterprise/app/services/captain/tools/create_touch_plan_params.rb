# frozen_string_literal: true

class Captain::Tools::CreateTouchPlanParams < RubyLLM::Schema
  string :name, description: 'Follow-up scenario name', min_length: 1
  string :description, description: 'Optional follow-up scenario description', required: false
  array :entity_kinds, description: 'Supported entity kinds', of: :string, min_items: 1, required: false
  array :touches, description: 'One or more typed touch definitions', min_items: 1 do
    object do
      string :action_type, enum: %w[send_message], required: false
      string :content_kind, enum: %w[free_text channel_template], required: false
      string :text_mode, enum: %w[static ai], required: false
      string :body, required: false
      string :instructions, required: false
      string :timing_mode, enum: %w[absolute relative], required: false
      string :scheduled_at, description: 'ISO8601 absolute delivery time', required: false
      string :relative_anchor, required: false
      integer :relative_offset_seconds, required: false
      string :relative_time_mode, enum: %w[inherit_anchor_time fixed_time_of_day], required: false
      string :relative_time_of_day, pattern: '^(?:[01]\\d|2[0-3]):[0-5]\\d$', required: false
      string :timezone, required: false
      integer :target_inbox_id, minimum: 1, required: false
      boolean :auto_cancel_on_incoming, required: false
      string :repeat_mode, enum: %w[once daily weekly monthly weekdays], required: false
      string :repeat_until_at, description: 'ISO8601 repeat end time', required: false
      string :entity_kind, enum: %w[conversation deal task appointment], required: false
      string :post_delivery_action, required: false
      array :attachments, of: :integer, required: false
      object :template_params, required: false do
        additional_properties true
      end
      object :metadata, required: false do
        additional_properties true
      end
    end
  end
end
