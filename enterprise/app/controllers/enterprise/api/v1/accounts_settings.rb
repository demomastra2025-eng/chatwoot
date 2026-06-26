module Enterprise::Api::V1::AccountsSettings
  private

  def permitted_settings_attributes
    super + [
      { conversation_required_attributes: [] },
      {
        conversation_status_reason_config: [
          { open: [:required, { options: [] }] },
          { resolved: [:required, { options: [] }] },
          { pending: [:required, { options: [] }] },
          { snoozed: [:required, { options: [] }] }
        ]
      }
    ]
  end
end
