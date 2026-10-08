# frozen_string_literal: true

FactoryBot.define do
  factory :inbox_member do
    user { create(:user, :with_avatar) }
    inbox

    # Account/inbox creation may have already inserted this fixture's membership.
    # Reuse it only for create; build must still exercise strict model validation.
    to_create do |member|
      existing_member = InboxMember.find_by(inbox_id: member.inbox_id, user_id: member.user_id)
      if existing_member
        additional_attributes = member.changed - %w[inbox_id user_id]
        if additional_attributes.any?
          raise ArgumentError, "Cannot reuse an inbox member with overridden attributes: #{additional_attributes.join(', ')}"
        end

        member.id = existing_member.id
        member.reload
      else
        member.save!
      end
    end
  end
end
