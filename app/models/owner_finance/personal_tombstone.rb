# frozen_string_literal: true

class OwnerFinance::PersonalTombstone < ApplicationRecord
  validates :row_fingerprint_sha256, presence: true, uniqueness: true
  validates :hidden_at, presence: true

  def self.merchant_hash_for(merchant_name)
    norm = OwnerFinance.normalize_merchant_key(merchant_name)
    return nil if norm.blank?

    Digest::SHA256.hexdigest("owner_finance_merchant:#{norm}")
  end

  def self.external_hide_fingerprint(external_source_key)
    return nil if external_source_key.blank?

    Digest::SHA256.hexdigest("external_hide|#{external_source_key}")
  end

  def self.always_hidden_merchant?(merchant_name)
    hash = merchant_hash_for(merchant_name)
    return false if hash.blank?

    exists?(merchant_key_hash: hash, hide_merchant_always: true)
  end

  def self.hidden_record?(fingerprint: nil, external_source_key: nil, merchant: nil)
    fps = [fingerprint.presence, external_hide_fingerprint(external_source_key)].compact
    return true if fps.any? && exists?(row_fingerprint_sha256: fps)

    merchant.present? && always_hidden_merchant?(merchant)
  end
end
