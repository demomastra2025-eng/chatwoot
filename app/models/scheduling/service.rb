# == Schema Information
#
# Table name: scheduling_services
#
#  id                :bigint           not null, primary key
#  active            :boolean          default(TRUE), not null
#  base_price        :integer          default(0), not null
#  category          :string
#  custom_attributes :jsonb            not null
#  description       :text
#  direction         :string
#  duration_min      :integer          default(30), not null
#  embedded_at       :datetime
#  embedding         :vector(1536)
#  embedding_checksum :string
#  embedding_model   :string
#  name              :string           not null
#  service_type      :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#
# Indexes
#
#  idx_scheduling_services_account_medelement_code_unique  (account_id, ((custom_attributes ->> 'medelement_nomenclature_code'::text))) UNIQUE WHERE (NULLIF(btrim((custom_attributes ->> 'medelement_nomenclature_code'::text)), ''::text) IS NOT NULL)
#  idx_scheduling_services_on_account_active_name          (account_id,active,name)
#  index_scheduling_services_on_account_id                 (account_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#

class Scheduling::Service < ApplicationRecord
  # The vector of the service search (1536 numbers, about 12 KB a row) is written and searched by SQL only, see Scheduling::ServiceIndex:
  # a service read for a list, a booking or the lexical package search must not carry it.
  self.ignored_columns += %w[embedding]

  belongs_to :account

  has_many :appointments, class_name: 'Scheduling::Appointment', dependent: :nullify, inverse_of: :service
  has_many :prices, class_name: 'Scheduling::ServicePrice', dependent: :destroy, inverse_of: :service
  has_many :resource_stats, class_name: 'Scheduling::ResourceServiceStat', dependent: :destroy_async, inverse_of: :service

  validates :name, presence: true
  validates :base_price, numericality: { greater_than_or_equal_to: 0, only_integer: true }
  validates :duration_min,
            inclusion: {
              in: Scheduling::Constants::MIN_DURATION_MINUTES..Scheduling::Constants::MAX_DURATION_MINUTES
            }

  after_commit :refresh_embedding_later, on: %i[create update]

  scope :ordered, -> { order(:name, :id) }
  scope :active, -> { where(active: true) }

  # A service imported from MedElement. Its duration_min is the column default, not a real length (MedElement gives none): the real
  # length comes from the visit history (see Scheduling::VisitDuration).
  def medelement_service?
    custom_attributes.to_h['medelement_nomenclature_code'].to_s.strip.present?
  end

  private

  # A save whose embedded text (name, aliases, category) is the one of the stored vector costs nothing: a MedElement catalog sync saves
  # every service and changes only its last-seen mark. Saves in a burst share one delayed job per account.
  def refresh_embedding_later
    return if embedding_checksum.present? && embedding_checksum == Scheduling::ServiceIndex.checksum(self)

    Scheduling::ServiceEmbeddingJob.enqueue(account_id)
  rescue StandardError => e
    Rails.logger.warn("[Scheduling::Service] embedding refresh not queued for service #{id}: #{e.class}: #{e.message}")
  end
end
