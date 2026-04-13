FactoryBot.define do
  factory :reminder_group do
    account
    creator { create(:user, account: account, role: :administrator) }
    sequence(:name) { |n| "Touch plan #{n}" }
    description { 'Default follow-up sequence' }
    entity_kinds { ['appointment'] }
    active { true }
    touches do
      [
        {
          action_type: 'send_message',
          content_kind: 'free_text',
          text_mode: 'static',
          timing_mode: 'relative',
          relative_anchor: 'appointment.starts_at',
          relative_offset_seconds: -86_400,
          timezone: 'UTC',
          body: 'Appointment reminder',
          attachments: [],
          template_params: {},
          metadata: {}
        }
      ]
    end
  end
end
