# == Schema Information
#
# Table name: lead_submissions
#
#  id                :bigint           not null, primary key
#  external_ref      :string
#  field_values      :jsonb            not null
#  idempotency_key   :string
#  payload           :jsonb            not null
#  processed_at      :datetime
#  processing_errors :jsonb            not null
#  source_kind       :string           not null
#  status            :string           default("received"), not null
#  utm               :jsonb            not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint           not null
#  contact_id        :bigint
#  contact_inbox_id  :bigint
#  conversation_id   :bigint
#  inbox_id          :bigint
#  lead_form_id      :bigint           not null
#
# Indexes
#
#  idx_on_account_id_lead_form_id_external_ref_9960822a16       (account_id,lead_form_id,external_ref) UNIQUE WHERE (external_ref IS NOT NULL)
#  idx_on_account_id_lead_form_id_idempotency_key_8efec97c53  (account_id,lead_form_id,idempotency_key) UNIQUE WHERE (idempotency_key IS NOT NULL)
#  idx_on_account_id_source_kind_created_at_6919889fce         (account_id,source_kind,created_at)
#  index_lead_submissions_on_account_id                       (account_id)
#  index_lead_submissions_on_contact_id                      (contact_id)
#  index_lead_submissions_on_contact_inbox_id                (contact_inbox_id)
#  index_lead_submissions_on_conversation_id                 (conversation_id)
#  index_lead_submissions_on_field_values                    (field_values) USING gin
#  index_lead_submissions_on_inbox_id                        (inbox_id)
#  index_lead_submissions_on_lead_form_id                    (lead_form_id)
#  index_lead_submissions_on_payload                         (payload) USING gin
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (contact_id => contacts.id)
#  fk_rails_...  (contact_inbox_id => contact_inboxes.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#  fk_rails_...  (lead_form_id => lead_forms.id)
#
class LeadSubmission < ApplicationRecord
  STATUSES = %w[received processed failed].freeze

  belongs_to :account
  belongs_to :lead_form
  belongs_to :inbox, optional: true
  belongs_to :contact, optional: true
  belongs_to :contact_inbox, optional: true
  belongs_to :conversation, optional: true

  before_validation :sync_account_and_source
  before_validation :normalize_status
  before_validation :normalize_json_columns

  validates :source_kind, :status, presence: true
  validates :source_kind, inclusion: { in: LeadForm::SOURCE_KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :external_ref, uniqueness: { scope: [:account_id, :lead_form_id] }, allow_blank: true
  validates :idempotency_key, uniqueness: { scope: [:account_id, :lead_form_id] }, allow_blank: true
  validate :associations_belong_to_account

  scope :ordered, -> { order(created_at: :desc, id: :desc) }
  scope :for_source, ->(source_kind) { where(source_kind: source_kind) if source_kind.present? }
  scope :for_status, ->(status) { where(status: status) if status.present? }

  def processed?
    status == 'processed'
  end

  def failed?
    status == 'failed'
  end

  private

  def associations_belong_to_account
    return if account_id.blank?

    {
      lead_form: lead_form,
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      conversation: conversation
    }.each do |name, record|
      next if record.blank?

      record_account_id = record.respond_to?(:account_id) ? record.account_id : record.inbox&.account_id
      next if record_account_id == account_id

      errors.add("#{name}_id", 'must belong to the same account')
    end
  end

  def normalize_json_columns
    self.field_values = {} unless field_values.is_a?(Hash)
    self.utm = {} unless utm.is_a?(Hash)
    self.payload = {} unless payload.is_a?(Hash)
    self.processing_errors = {} unless processing_errors.is_a?(Hash)
  end

  def normalize_status
    self.status = status.to_s.strip.presence || 'received'
  end

  def sync_account_and_source
    return if lead_form.blank?

    self.account ||= lead_form.account
    self.inbox ||= lead_form.inbox
    self.source_kind ||= lead_form.source_kind
  end
end
