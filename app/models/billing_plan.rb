# == Schema Information
#
# Table name: billing_plans
#
#  id           :bigint           not null, primary key
#  code         :string           not null
#  entitlements :jsonb            not null
#  metadata     :jsonb            not null
#  name         :string           not null
#  public       :boolean          default(FALSE), not null
#  status       :string           default("draft"), not null
#  version      :integer          default(1), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#
# Indexes
#
#  index_billing_plans_on_code_and_version   (code,version) UNIQUE
#  index_billing_plans_on_status_and_public  (status,public)
#
class BillingPlan < ApplicationRecord
  STATUSES = %w[draft active retired].freeze
  PUBLISHED_ATTRIBUTES = %w[code name version entitlements].freeze

  has_many :prices, class_name: 'BillingPlanPrice', dependent: :restrict_with_error
  has_many :subscriptions, class_name: 'BillingSubscription', dependent: :restrict_with_error

  enum :status, STATUSES.index_with(&:itself)

  validates :code, :name, presence: true
  validates :version, numericality: { only_integer: true, greater_than: 0 }
  validates :code, uniqueness: { scope: :version }
  validate :entitlements_are_an_object
  validate :metadata_is_object
  validate :published_plan_is_immutable, on: :update

  private

  def entitlements_are_an_object
    errors.add(:entitlements, 'must be an object') unless entitlements.is_a?(Hash)
  end

  def metadata_is_object
    errors.add(:metadata, 'must be an object') unless metadata.is_a?(Hash)
  end

  def published_plan_is_immutable
    return if status_in_database == 'draft'
    return if PUBLISHED_ATTRIBUTES.none? { |attribute| will_save_change_to_attribute?(attribute) }

    errors.add(:base, 'published plan versions cannot be changed')
  end
end
