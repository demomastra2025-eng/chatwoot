# frozen_string_literal: true

# The reminder on «Сводка» for a super admin who signs in with the password alone (app/views/super_admin/shared/_two_factor_notice).
# A super admin can hide it for himself with «Больше не показывать»: the mark is kept on his own user (custom_attributes), so it
# is his choice only and it follows him to another browser. It is a choice about a reminder, not about the protection: the card of
# his user keeps saying that the second step is off, and the choice can be taken back there. Both changes leave an entry of the audit log.
#
#   SuperAdmin::TwoFactorNotice.visible_for?(user)   # => true while the second step is off and the reminder is not hidden
#   SuperAdmin::TwoFactorNotice.hide!(user, request: request)
#   SuperAdmin::TwoFactorNotice.restore!(user, request: request)
module SuperAdmin::TwoFactorNotice
  KEY = 'two_factor_notice_hidden_at'

  class << self
    def visible_for?(user)
      !user.mfa_enabled? && !hidden?(user)
    end

    def hidden?(user)
      user.custom_attributes.to_h[KEY].present?
    end

    def hide!(user, request: nil)
      change!(user, "COALESCE(custom_attributes, '{}'::jsonb) || ?::jsonb", { KEY => Time.current.iso8601 }.to_json)
      record(user, 'hide_two_factor_notice', 'two_factor_notice' => %w[shown hidden], request: request)
    end

    def restore!(user, request: nil)
      change!(user, "COALESCE(custom_attributes, '{}'::jsonb) - ?::text", KEY)
      record(user, 'show_two_factor_notice', 'two_factor_notice' => %w[hidden shown], request: request)
    end

    private

    # One statement on the one column, without the validations and callbacks of the user: a record with an old defect can still change it
    def change!(user, expression, value)
      User.where(id: user.id).update_all(["custom_attributes = #{expression}", value])
      user.reload
    end

    def record(user, action, changes, request:)
      SuperAdmin::PlatformAudit.record(auditable: user, action: action, actor: user, changes: changes, request: request)
    end
  end
end
