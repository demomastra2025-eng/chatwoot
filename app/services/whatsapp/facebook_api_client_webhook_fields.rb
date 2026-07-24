module Whatsapp::FacebookApiClientWebhookFields
  FIELDS = %w[
    messages
    account_update
    smb_message_echoes
    calls
    account_alerts
    account_review_update
    business_capability_update
    message_template_components_update
    message_template_quality_update
    message_template_status_update
    phone_number_name_update
    phone_number_quality_update
    security
    template_category_update
    user_preferences
  ].freeze
end
