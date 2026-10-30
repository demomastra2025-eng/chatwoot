# frozen_string_literal: true

class OwnerFinance::Counterparty < ApplicationRecord
  KINDS = %w[client vendor partner tax other].freeze

  has_many :contracts, class_name: 'OwnerFinance::Contract', dependent: :nullify
  has_many :deadlines, class_name: 'OwnerFinance::Deadline', dependent: :nullify
  has_many :transactions, class_name: 'OwnerFinance::TransactionRecord', dependent: :nullify

  before_validation :ensure_normalized_key

  validates :display_name, presence: true
  validates :normalized_key, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS }

  private

  def ensure_normalized_key
    base = OwnerFinance.normalize_merchant_key(display_name)
    self.normalized_key = base.presence || "cp-#{SecureRandom.hex(4)}" if normalized_key.blank?
  end
end
