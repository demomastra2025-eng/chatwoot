# Hands the client over together with the deal.
#
# Owner decision for release E (restores what PROD did before the sync was
# dropped): when the owner of a deal changes, the owner of the deal's primary
# contact becomes the same user, or nobody when the deal was left without an
# owner. Non-primary contacts are never touched, and a manual owner of the
# contact is overwritten by the next owner change of the deal.
#
# The contact keeps its own after_commit (Contacts::OwnerSyncService) that moves
# the client's conversations, tasks and other primary deals to the same owner.
# Both directions only write rows whose owner really differs, so they settle
# after one hop and never loop.
#
# This class is the only place that knows the rule and Crm::Deal is the only
# caller. Turning it into an opt-in ("also hand over the client" checkbox) is a
# change of #enabled? here and nothing else.
class Crm::Deals::ContactOwnerSync
  def self.call(deals)
    new(deals: deals).perform
  end

  def initialize(deals:)
    @deals = Array(deals).select { |deal| deal.persisted? && !deal.destroyed? }
  end

  # Returns how many contacts were handed over. Deals are grouped by account and
  # owner so that a bulk update looks the contacts up once per group instead of
  # once per deal.
  def perform
    return 0 unless enabled?

    deals.group_by { |deal| [deal.account_id, deal.owner_id] }.sum do |(account_id, owner_id), group|
      contacts_to_hand_over(account_id, owner_id, group.map(&:id)).sum { |contact| hand_over(contact, owner_id) }
    end
  end

  private

  attr_reader :deals

  def enabled?
    true
  end

  def contacts_to_hand_over(account_id, owner_id, deal_ids)
    primary_contact_ids = Crm::DealContact.where(account_id: account_id, deal_id: deal_ids, primary: true).select(:contact_id)
    scope = Contact.where(account_id: account_id, id: primary_contact_ids)
    return scope.where.not(owner_id: nil) if owner_id.blank?

    scope.where(owner_id: nil).or(scope.where.not(owner_id: owner_id))
  end

  # The deal is already committed here, so a contact that cannot be saved must
  # not turn the deal update into an error response.
  def hand_over(contact, owner_id)
    contact.update!(owner_id: owner_id)
    1
  rescue ActiveRecord::RecordInvalid, ActiveRecord::StaleObjectError => e
    ChatwootExceptionTracker.new(e, account: contact.account).capture_exception
    0
  end
end
