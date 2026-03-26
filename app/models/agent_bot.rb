# == Schema Information
#
# Table name: agent_bots
#
#  id           :bigint           not null, primary key
#  bot_config   :jsonb
#  bot_type     :integer          default("webhook")
#  description  :string
#  name         :string
#  outgoing_url :string
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :bigint
#
# Indexes
#
#  index_agent_bots_on_account_id  (account_id)
#

class AgentBot < ApplicationRecord
  include AccessTokenable
  include Avatarable

  scope :accessible_to, lambda { |account|
    account_id = account&.id
    where(account_id: [nil, account_id])
  }

  has_many :agent_bot_inboxes, dependent: :destroy_async
  has_many :inboxes, through: :agent_bot_inboxes
  has_many :messages, as: :sender, dependent: :nullify
  has_many :assigned_conversations, class_name: 'Conversation',
                                    foreign_key: :assignee_agent_bot_id,
                                    dependent: :nullify,
                                    inverse_of: :assignee_agent_bot
  belongs_to :account, optional: true
  enum bot_type: { webhook: 0, flow_builder: 1 }

  validates :outgoing_url, length: { maximum: Limits::URL_LENGTH_LIMIT }
  validate :validate_configuration

  before_validation :normalize_flow_builder_config

  def self.default_flow_builder_config
    AgentBots::FlowBuilder::ConfigNormalizer.default_config
  end

  def available_name
    name
  end

  def push_event_data(inbox = nil)
    {
      id: id,
      name: name,
      avatar_url: avatar_url || inbox&.avatar_url,
      type: 'agent_bot'
    }
  end

  def webhook_data
    {
      id: id,
      name: name,
      type: 'agent_bot'
    }
  end

  def system_bot?
    account.nil?
  end

  private

  def normalize_flow_builder_config
    return unless flow_builder?

    self.bot_config = AgentBots::FlowBuilder::ConfigNormalizer.normalize(bot_config)
  end

  def validate_configuration
    if webhook?
      errors.add(:outgoing_url, :blank) if outgoing_url.blank? && !system_bot?
      return
    end

    validator = AgentBots::FlowBuilder::ConfigValidator.new(bot_config: bot_config)
    return if validator.valid?

    validator.errors.each { |message| errors.add(:bot_config, message) }
  end
end
