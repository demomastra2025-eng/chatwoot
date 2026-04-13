class Reminders::CreateService
  DEFAULT_TIMEZONE = 'UTC'.freeze

  attr_reader :account, :attributes, :creator, :remindable, :reminder_group

  def initialize(account:, remindable:, attributes:, creator: nil, reminder_group: nil)
    @account = account
    @remindable = remindable
    @attributes = normalize_attributes(attributes)
    @creator = creator
    @reminder_group = reminder_group
  end

  def perform
    reminder = account.reminders.new(
      reminder_attributes.merge(
        remindable: remindable,
        reminder_group: reminder_group
      )
    )
    reminder.creator = creator if creator.is_a?(User)
    reminder.save!
    reminder.approve! if reminder.draft? && reminder.ready_for_pending?
    reminder
  end

  private

  def normalize_attributes(value)
    raw = if value.is_a?(ActionController::Parameters)
            value.to_unsafe_h
          elsif value.respond_to?(:to_h)
            value.to_h
          else
            value
          end

    raise ArgumentError, 'Touch attributes must be a hash' unless raw.is_a?(Hash)

    Reminders::DefinitionNormalizer.call(raw).with_indifferent_access
  end

  # rubocop:disable Metrics/MethodLength
  def reminder_attributes
    {
      owner_id: attributes[:owner_id],
      conversation_id: attributes[:conversation_id],
      action_type: attributes[:action_type] || 'send_message',
      content_kind: attributes[:content_kind] || 'free_text',
      text_mode: attributes[:text_mode],
      timing_mode: attributes[:timing_mode] || 'absolute',
      repeat_mode: attributes[:repeat_mode] || 'once',
      repeat_until_at: attributes[:repeat_until_at],
      relative_anchor: attributes[:relative_anchor],
      relative_offset_seconds: attributes[:relative_offset_seconds],
      scheduled_at: attributes[:scheduled_at],
      timezone: attributes[:timezone].presence || DEFAULT_TIMEZONE,
      body: attributes[:body],
      instructions: attributes[:instructions],
      attachments: Array(attributes[:attachments]),
      template_params: (attributes[:template_params] || {}).to_h,
      metadata: (attributes[:metadata] || {}).to_h,
      auto_cancel_on_incoming: normalize_boolean(attributes[:auto_cancel_on_incoming], default: true),
      target_inbox_id: attributes[:target_inbox_id],
      target_contact_id: attributes[:target_contact_id],
      target_contact_inbox_id: attributes[:target_contact_inbox_id],
      target_conversation_id: attributes[:target_conversation_id]
    }.compact
  end
  # rubocop:enable Metrics/MethodLength

  def normalize_boolean(value, default:)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end
end
