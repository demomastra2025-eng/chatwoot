# M5(a), event driven: enqueued after a MedElement sync of one patient commits (never on deploy or as a mass job).
class Contacts::SharedPhonePromotionJob < ApplicationJob
  queue_as :medium

  def perform(card_id)
    card = Contact.find_by(id: card_id)
    return if card.blank?

    result = promote(card)
    hint_blocked_promotion(card) if result&.status == :blocked
    result
  end

  private

  def promote(card)
    result = Contacts::SharedPhonePromotionService.new(card: card, basis: 'medelement').perform
    log(card, result.status, result.reason)
    result
  rescue Contacts::SharedPhonePromotionService::Error => e
    log(card, 'skipped', e.code)
    nil
  end

  # A block only the administrator can resolve (siblings, several previous holders, …) leaves a hint in the card.
  def hint_blocked_promotion(card)
    decision = Contacts::SharedPhonePromotionPolicy.auto_decision(card.reload)
    Contacts::SharedPhoneHint.ensure_for_blocked_promotion!(card, decision) unless decision.promote?
  end

  def log(card, status, reason)
    Rails.logger.info({ event: 'shared_phone_auto_promotion', account_id: card.account_id, contact_id: card.id, status: status,
                        reason: reason }.compact.to_json)
  end
end
