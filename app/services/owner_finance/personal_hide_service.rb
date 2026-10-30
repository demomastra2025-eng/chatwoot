# frozen_string_literal: true

class OwnerFinance::PersonalHideService
  def initialize(transaction:, hide_merchant_always: false)
    @transaction = transaction
    @hide_merchant_always = ActiveModel::Type::Boolean.new.cast(hide_merchant_always)
  end

  def perform
    ActiveRecord::Base.transaction do
      merchant_name = @transaction.merchant
      merchant_hash = OwnerFinance::PersonalTombstone.merchant_hash_for(merchant_name)
      targets = collect_targets(merchant_hash)
      targets.each { |item| tombstone_and_destroy!(item, merchant_hash) }
      scrub_learned_counterparty!(merchant_name)
      { hidden_count: targets.size, hide_merchant_always: @hide_merchant_always }
    end
  end

  private

  def tombstone_and_destroy!(item, merchant_hash)
    fingerprints_for(item).each { |fingerprint| save_tombstone!(fingerprint, item.occurred_on, merchant_hash) }
    item.destroy!
  end

  def fingerprints_for(item)
    ext_fp = OwnerFinance::PersonalTombstone.external_hide_fingerprint(item.external_source_key)
    primary = item.row_fingerprint_sha256.presence || ext_fp || fallback_fingerprint(item)
    [primary, ext_fp].compact.uniq
  end

  def save_tombstone!(fingerprint, occurred_on, merchant_hash)
    tombstone = OwnerFinance::PersonalTombstone.find_or_initialize_by(row_fingerprint_sha256: fingerprint)
    tombstone.merchant_key_hash = merchant_hash if merchant_hash.present?
    tombstone.hide_merchant_always = true if @hide_merchant_always && merchant_hash.present?
    tombstone.occurred_on ||= occurred_on
    tombstone.hidden_at = Time.current
    tombstone.save!
  end

  def scrub_learned_counterparty!(merchant_name)
    norm = OwnerFinance.normalize_merchant_key(merchant_name)
    counterparty = norm.present? ? OwnerFinance::Counterparty.find_by(normalized_key: norm) : nil
    return unless counterparty

    if counterparty.external_source_key.blank? && unreferenced_counterparty?(counterparty)
      counterparty.destroy!
    elsif @hide_merchant_always
      counterparty.update!(default_category: nil, default_pnl_treatment: nil)
    end
  end

  def unreferenced_counterparty?(counterparty)
    !counterparty.contracts.exists? && !counterparty.deadlines.exists? && !counterparty.transactions.exists?
  end

  def collect_targets(merchant_hash)
    return [@transaction] unless @hide_merchant_always && merchant_hash.present?

    norm = OwnerFinance.normalize_merchant_key(@transaction.merchant)
    siblings = OwnerFinance::TransactionRecord.needs_review.select do |candidate|
      OwnerFinance.normalize_merchant_key(candidate.merchant) == norm
    end
    ([@transaction] + siblings).uniq(&:id)
  end

  def fallback_fingerprint(item)
    norm_merchant = OwnerFinance.normalize_merchant_key(item.merchant)
    Digest::SHA256.hexdigest("manual_hide|#{item.occurred_on}|#{format('%.2f', item.amount)}|#{item.currency}|#{norm_merchant}")
  end
end
