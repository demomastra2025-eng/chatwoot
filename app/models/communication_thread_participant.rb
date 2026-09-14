# == Schema Information
#
# Table name: communication_thread_participants
#
#  id                      :bigint           not null, primary key
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#  added_by_id             :bigint
#  communication_thread_id :bigint           not null
#  user_id                 :bigint           not null
#
class CommunicationThreadParticipant < ApplicationRecord
  belongs_to :account
  belongs_to :communication_thread
  belongs_to :user
  belongs_to :added_by, class_name: 'User', optional: true

  audited associated_with: :account

  before_validation :ensure_account

  validates :account_id, presence: true
  validates :user_id, uniqueness: { scope: :communication_thread_id }
  validate :thread_belongs_to_account
  validate :user_belongs_to_account
  validate :added_by_belongs_to_account

  def self.find_or_create_for!(communication_thread:, user_id:, added_by: nil, audit_comment: nil)
    scope = communication_thread.communication_thread_participants
    scope.find_by(user_id: user_id) || create_for_scope!(scope, user_id, added_by, audit_comment)
  end

  def self.create_for_scope!(scope, user_id, added_by, audit_comment)
    transaction(requires_new: true) do
      scope.create!(user_id: user_id, added_by: added_by, audit_comment: audit_comment)
    end
  rescue ActiveRecord::RecordNotUnique
    scope.find_by!(user_id: user_id)
  rescue ActiveRecord::RecordInvalid => e
    existing_record = scope.find_by(user_id: user_id)
    return existing_record if existing_record.present? && e.record.errors.of_kind?(:user_id, :taken)

    raise
  end
  private_class_method :create_for_scope!

  private

  def ensure_account
    self.account ||= communication_thread&.account
  end

  def thread_belongs_to_account
    return if communication_thread.blank? || account_id.blank? || communication_thread.account_id == account_id

    errors.add(:communication_thread, 'must belong to the same account')
  end

  def user_belongs_to_account
    return if user_id.blank? || account_id.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: user_id)

    errors.add(:user, 'must be an active workspace member')
  end

  def added_by_belongs_to_account
    return if added_by_id.blank? || account_id.blank?
    return if AccountUser.exists?(account_id: account_id, user_id: added_by_id)

    errors.add(:added_by, 'must belong to the same account')
  end
end
