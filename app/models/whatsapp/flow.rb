class Whatsapp::Flow < ApplicationRecord
  self.table_name = 'whatsapp_flows'

  STATUSES = %w[draft published deprecated blocked unknown].freeze
  MODES = %w[draft published].freeze

  belongs_to :account
  belongs_to :inbox
  has_many :flow_sessions,
           class_name: 'Whatsapp::FlowSession',
           foreign_key: :whatsapp_flow_id,
           inverse_of: :flow,
           dependent: :destroy

  before_validation :normalize_json_attributes
  before_validation :assign_account_from_inbox

  validates :name, :status, presence: true
  validates :name, uniqueness: { scope: %i[account_id inbox_id] }
  validates :provider_flow_id, uniqueness: { scope: %i[account_id inbox_id] }, allow_blank: true
  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }, allow_blank: true
  validate :inbox_belongs_to_account
  validate :inbox_supports_whatsapp_flows

  scope :latest_first, -> { order(updated_at: :desc, id: :desc) }
  scope :sendable, -> { where(status: 'published') }

  def display_title
    title.presence || name
  end

  private

  def assign_account_from_inbox
    self.account ||= inbox&.account
  end

  def normalize_json_attributes
    self.flow_json = flow_json.to_h if flow_json.blank? || flow_json.respond_to?(:to_h)
    self.metadata = metadata.to_h if metadata.blank? || metadata.respond_to?(:to_h)
  end

  def inbox_belongs_to_account
    return if inbox.blank? || account.blank?
    return if inbox.account_id == account_id

    errors.add(:inbox, 'must belong to the current account')
  end

  def inbox_supports_whatsapp_flows
    return if inbox.blank?
    return if inbox.whatsapp? && inbox.channel.provider == 'whatsapp_cloud'

    errors.add(:inbox, 'must be a WhatsApp Cloud inbox')
  end
end
