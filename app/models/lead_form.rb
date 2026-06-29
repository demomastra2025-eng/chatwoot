# == Schema Information
#
# Table name: lead_forms
#
#  id           :bigint           not null, primary key
#  description  :text
#  external_ref :string
#  field_schema :jsonb            not null
#  name         :string           not null
#  public_token :string           not null
#  settings     :jsonb            not null
#  source_kind  :string           not null
#  status       :string           default("active"), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint           not null
#  inbox_id     :bigint
#
# Indexes
#
#  idx_on_account_id_source_kind_external_ref_7153b85ff3      (account_id,source_kind,external_ref) UNIQUE WHERE (external_ref IS NOT NULL)
#  index_lead_forms_on_account_id                             (account_id)
#  index_lead_forms_on_account_id_and_source_kind_and_status  (account_id,source_kind,status)
#  index_lead_forms_on_inbox_id                               (inbox_id)
#  index_lead_forms_on_public_token                           (public_token) UNIQUE
#  index_lead_forms_on_settings                               (settings) USING gin
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class LeadForm < ApplicationRecord
  SOURCE_KINDS = %w[api meta widget].freeze
  STATUSES = %w[active paused archived].freeze
  META_CONNECTION_CHANNEL_TYPES = %w[
    Channel::FacebookPage
    Channel::Instagram
    Channel::Whatsapp
  ].freeze

  belongs_to :account
  belongs_to :inbox, optional: true
  has_many :lead_submissions, dependent: :destroy_async

  before_validation :ensure_public_token
  before_validation :normalize_json_columns
  before_validation :normalize_source_kind
  before_validation :normalize_status

  validates :name, :source_kind, :status, :public_token, presence: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :public_token, uniqueness: true
  validates :external_ref, uniqueness: { scope: [:account_id, :source_kind] }, allow_blank: true
  validate :source_configuration_is_complete
  validate :field_schema_is_valid
  validate :inbox_belongs_to_account
  validate :meta_connection_inbox_belongs_to_account

  scope :ordered, -> { order(:source_kind, :name, :id) }
  scope :active, -> { where(status: 'active') }
  scope :for_source, ->(source_kind) { where(source_kind: source_kind) if source_kind.present? }

  def active?
    status == 'active'
  end

  def api?
    source_kind == 'api'
  end

  def meta?
    source_kind == 'meta'
  end

  def widget?
    source_kind == 'widget'
  end

  private

  def ensure_public_token
    self.public_token = SecureRandom.urlsafe_base64(32) if public_token.blank?
  end

  def inbox_belongs_to_account
    return if inbox.blank? || account_id.blank? || inbox.account_id == account_id

    errors.add(:inbox_id, 'must belong to the same account')
  end

  def source_configuration_is_complete
    errors.add(:inbox_id, "can't be blank") if inbox.blank?

    return unless meta?

    errors.add(:external_ref, "can't be blank") if external_ref.blank? && settings.to_h['meta_form_id'].blank?
    errors.add(:settings, 'meta connection inbox is required') if settings.to_h['meta_connection_inbox_id'].blank?
  end

  def meta_connection_inbox_belongs_to_account
    return unless meta?

    meta_connection_inbox_id = settings.to_h['meta_connection_inbox_id'].presence
    return if meta_connection_inbox_id.blank?

    meta_connection_inbox = account&.inboxes&.find_by(id: meta_connection_inbox_id)
    unless meta_connection_inbox
      errors.add(:settings, 'meta connection inbox must belong to the same account')
      return
    end

    return if META_CONNECTION_CHANNEL_TYPES.include?(meta_connection_inbox.channel_type)

    errors.add(:settings, 'meta connection inbox must be a Meta channel')
  end

  def field_schema_is_valid
    errors.add(:field_schema, "can't be blank") if api? && field_schema.blank?

    field_schema.each do |field|
      field = field.to_h
      errors.add(:field_schema, 'field name is required') if field['name'].blank?
      errors.add(:field_schema, 'field label is required') if field['label'].blank?
      errors.add(:field_schema, 'field type is required') if field['type'].blank?
    end
  end

  def normalize_json_columns
    self.field_schema = [] unless field_schema.is_a?(Array)
    self.settings = {} unless settings.is_a?(Hash)
  end

  def normalize_source_kind
    self.source_kind = source_kind.to_s.strip.presence
  end

  def normalize_status
    self.status = status.to_s.strip.presence || 'active'
  end
end
