class AutomationRuleGroup < ApplicationRecord
  belongs_to :account
  has_many :automation_rules, dependent: :restrict_with_exception
  has_many :automation_executions, dependent: :restrict_with_exception

  validates :name, :event_name, presence: true
  validates :event_name, inclusion: { in: AutomationRule::SUPPORTED_EVENT_NAMES }
end
