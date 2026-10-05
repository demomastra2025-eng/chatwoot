# frozen_string_literal: true

# The account-level model choices of the Luna 6 cut-over. The cut-over clears them, so the account follows the platform
# default afterwards (which is what makes the installation default the one quick switch); a rollback puts back exactly
# the keys and values of the snapshot. Both refuse to run when an override is in neither state.
class Llm::CaptainLunaRollout::AccountOverrides
  def initialize(features:)
    @features = features
  end

  # Only the accounts that have at least one of the overrides; the others have nothing to clear or to restore.
  def snapshot(accounts)
    accounts.filter_map do |account|
      overrides = current(account).map { |feature, value| { feature: feature, before: value } }
      { account_id: account.id, overrides: overrides } if overrides.any?
    end
  end

  def verify!(accounts, entries)
    by_account = entries.index_by { |entry| entry[:account_id] }
    raise Llm::CaptainLunaRollout::StalePlan, 'Account list changed' unless (by_account.keys - accounts.map(&:id)).empty?

    accounts.each { |account| verify_account!(account, by_account[account.id]) }
  end

  # Returns the number of accounts that were written.
  def clear!(accounts, entries)
    changed_accounts(accounts, entries) { |models, override| models.delete(override[:feature]) }
  end

  def restore!(accounts, entries)
    changed_accounts(accounts, entries) { |models, override| models[override[:feature]] = override[:before] }
  end

  private

  attr_reader :features

  def current(account)
    account.captain_models.to_h.stringify_keys.slice(*features)
  end

  # A choice that is present has to be the one of the snapshot; an absent one is the done state.
  def verify_account!(account, entry)
    before = (entry&.dig(:overrides) || []).to_h { |override| [override[:feature], override[:before]] }
    stale = current(account).find { |feature, value| before.fetch(feature, :absent) != value }
    return if stale.nil?

    raise Llm::CaptainLunaRollout::StalePlan, "A #{stale.first} model choice changed since the snapshot (account #{account.id})"
  end

  # The settings are written without validations: an unrelated stored choice (for instance a retired transcription
  # model) must not stop the cut-over of the account.
  def changed_accounts(accounts, entries)
    by_account = entries.index_by { |entry| entry[:account_id] }
    accounts.count do |account|
      models = account.captain_models.to_h.stringify_keys
      by_account.fetch(account.id, { overrides: [] })[:overrides].each { |override| yield models, override }
      next false if models == account.captain_models.to_h.stringify_keys

      account.captain_models = models
      account.save!(validate: false)
      true
    end
  end
end
