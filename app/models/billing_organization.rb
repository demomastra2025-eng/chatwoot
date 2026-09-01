# == Schema Information
#
# Table name: billing_organizations
#
#  id         :bigint           not null, primary key
#  name       :string           not null
#  status     :integer          default("active"), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class BillingOrganization < ApplicationRecord
  has_many :accounts, dependent: :restrict_with_error

  enum :status, { active: 0, suspended: 1 }

  validates :name, presence: true
end
