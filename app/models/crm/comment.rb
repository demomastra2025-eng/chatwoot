# == Schema Information
#
# Table name: crm_comments
#
#  id               :bigint           not null, primary key
#  body             :text             not null
#  commentable_type :string           not null
#  deleted_at       :datetime
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  commentable_id   :bigint           not null
#  user_id          :bigint           not null
#
# Indexes
#
#  index_crm_comments_on_account_and_commentable_created_at  (account_id,commentable_type,commentable_id,created_at)
#  index_crm_comments_on_account_id                          (account_id)
#  index_crm_comments_on_user_id                             (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class Crm::Comment < ApplicationRecord
  self.table_name = 'crm_comments'

  SUPPORTED_COMMENTABLE_TYPES = %w[Crm::Deal Crm::Task].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :commentable, polymorphic: true
  belongs_to :user, class_name: '::User'

  validates :body, presence: true
  validates :commentable_type, inclusion: { in: SUPPORTED_COMMENTABLE_TYPES }
  validate :commentable_belongs_to_account
  validate :user_belongs_to_account

  scope :kept, -> { where(deleted_at: nil) }
  scope :ordered, -> { order(created_at: :desc, id: :desc) }

  before_validation :normalize_body

  def soft_delete!
    update!(deleted_at: Time.zone.now)
  end

  private

  def commentable_belongs_to_account
    return if commentable.blank? || !commentable.respond_to?(:account_id)
    return if commentable.account_id == account_id

    errors.add(:commentable, 'must belong to the current account')
  end

  def normalize_body
    self.body = body.to_s.strip
  end

  def user_belongs_to_account
    return if user.blank? || account.users.exists?(id: user.id)

    errors.add(:user, 'must belong to the current account')
  end
end
