# == Schema Information
#
# Table name: campaign_audience_imports
#
#  id               :bigint           not null, primary key
#  claimed_at       :datetime
#  conflict_count   :integer          default(0), not null
#  created_count    :integer          default(0), not null
#  default_country  :string           not null
#  duplicate_count  :integer          default(0), not null
#  error_samples    :jsonb            not null
#  existing_count   :integer          default(0), not null
#  expires_at       :datetime         not null
#  invalid_count    :integer          default(0), not null
#  processing_error :string
#  recipient_count  :integer          default(0), not null
#  source_filename  :string           not null
#  status           :integer          default("pending"), not null
#  token            :string           not null
#  total_rows       :integer          default(0), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  created_by_id    :bigint
#  inbox_id         :bigint           not null
#
# Indexes
#
#  index_campaign_audience_imports_on_account_id                 (account_id)
#  index_campaign_audience_imports_on_account_id_and_expires_at  (account_id,expires_at)
#  index_campaign_audience_imports_on_account_id_and_status      (account_id,status)
#  index_campaign_audience_imports_on_created_by_id              (created_by_id)
#  index_campaign_audience_imports_on_inbox_id                   (inbox_id)
#  index_campaign_audience_imports_on_token                      (token) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (created_by_id => users.id) ON DELETE => nullify
#  fk_rails_...  (inbox_id => inboxes.id) ON DELETE => cascade
#
class CampaignAudienceImport < ApplicationRecord
  TOKEN_TTL = 24.hours

  belongs_to :account
  belongs_to :inbox
  belongs_to :created_by, class_name: 'User', optional: true
  has_many :recipients, class_name: 'CampaignAudienceRecipient', dependent: :delete_all
  has_one :campaign, dependent: :restrict_with_error
  has_one_attached :import_file

  before_destroy :ensure_import_source_purged, prepend: true

  enum status: { pending: 0, processing: 1, completed: 2, failed: 3 }

  validates :token, :source_filename, :default_country, :expires_at, presence: true
  validates :token, uniqueness: true
  validates :total_rows, :recipient_count, :created_count, :existing_count,
            :duplicate_count, :invalid_count, :conflict_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :inbox_belongs_to_account
  validate :creator_belongs_to_account

  scope :available, -> { completed.where(claimed_at: nil).where('expires_at > ?', Time.current) }

  def available?
    completed? && claimed_at.nil? && expires_at.future?
  end

  private

  def ensure_import_source_purged
    source_attached = ActiveStorage::Attachment.exists?(
      record_type: self.class.polymorphic_name,
      record_id: id,
      name: 'import_file'
    )
    return unless source_attached

    errors.add(:import_file, 'must be purged before deletion')
    throw(:abort)
  end

  def inbox_belongs_to_account
    return if inbox.blank? || inbox.account_id == account_id

    errors.add(:inbox_id, 'must belong to the same account')
  end

  def creator_belongs_to_account
    return if created_by.blank? || account.users.exists?(id: created_by_id)

    errors.add(:created_by_id, 'must belong to the same account')
  end
end
