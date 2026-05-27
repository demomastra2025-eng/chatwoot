# == Schema Information
#
# Table name: companies
#
#  id             :bigint           not null, primary key
#  contacts_count :integer
#  description    :text
#  domain         :string
#  name           :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#
# Indexes
#
#  index_companies_on_account_and_domain   (account_id,domain) UNIQUE WHERE (domain IS NOT NULL)
#  index_companies_on_account_id           (account_id)
#  index_companies_on_name_and_account_id  (name,account_id)
#
class Company < ApplicationRecord
  include Avatarable
  include LlmFormattable

  ACTIVITY_ROLLUP_INTERVAL = 5.minutes

  validates :account_id, presence: true
  validates :name, presence: true, length: { maximum: Limits::COMPANY_NAME_LENGTH_LIMIT }
  validates :domain, allow_blank: true, format: {
    with: /\A[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+\z/,
    message: I18n.t('errors.companies.domain.invalid')
  }
  validates :domain, uniqueness: { scope: :account_id }, if: -> { domain.present? }
  validates :description, length: { maximum: Limits::COMPANY_DESCRIPTION_LENGTH_LIMIT }
  validates :custom_attributes, jsonb_attributes_length: true

  belongs_to :account
  has_many :crm_deals, dependent: :nullify, class_name: '::Crm::Deal'
  has_many :contacts, dependent: :nullify
  has_many :scheduling_appointments, dependent: :nullify, class_name: 'Scheduling::Appointment'
  before_validation :prepare_company_attributes, :normalize_domain
  after_create_commit :fetch_favicon, if: -> { domain.present? }

  scope :ordered_by_name, -> { order(:name) }
  scope :search_by_name_or_domain, lambda { |query|
    where('name ILIKE :search OR domain ILIKE :search', search: "%#{query.strip}%")
  }

  scope :with_effective_contacts_count, lambda {
    select(
      "#{table_name}.*",
      "#{effective_contacts_count_sql} AS effective_contacts_count"
    )
  }

  scope :order_on_contacts_count, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order("#{effective_contacts_count_sql} #{direction}")
      )
    )
  }

  scope :order_on_last_activity_at, lambda { |direction|
    order(
      Arel::Nodes::SqlLiteral.new(
        sanitize_sql_for_order("\"companies\".\"last_activity_at\" #{direction} NULLS LAST")
      )
    )
  }

  def self.effective_contacts_count_sql
    <<~SQL.squish
      (
        SELECT COUNT(DISTINCT company_contact_ids.contact_id)
        FROM (
          SELECT contacts.id AS contact_id
          FROM contacts
          WHERE contacts.company_id = companies.id
            AND contacts.account_id = companies.account_id
          UNION
          SELECT crm_deal_contacts.contact_id AS contact_id
          FROM crm_deal_contacts
          INNER JOIN crm_deals ON crm_deals.id = crm_deal_contacts.deal_id
          WHERE crm_deals.company_id = companies.id
            AND crm_deal_contacts.account_id = companies.account_id
            AND crm_deals.account_id = companies.account_id
        ) company_contact_ids
      )
    SQL
  end

  def effective_contacts_count
    return self[:effective_contacts_count].to_i if has_attribute?(:effective_contacts_count)
    return contacts_count.to_i unless persisted?

    self.class.where(id: id).pick(Arel.sql(self.class.effective_contacts_count_sql)).to_i
  end

  def record_activity_at!(activity_at)
    return if last_activity_at.present? && last_activity_at > activity_at - ACTIVITY_ROLLUP_INTERVAL

    update!(last_activity_at: activity_at)
  end

  private

  def prepare_company_attributes
    self.additional_attributes = {} unless additional_attributes.is_a?(Hash)
    self.custom_attributes = {} unless custom_attributes.is_a?(Hash)
  end

  def normalize_domain
    self.domain = domain.to_s.strip.downcase.presence
  end

  def fetch_favicon
    Avatar::AvatarFromFaviconJob.set(wait: 5.seconds).perform_later(self)
  end
end
