class Companies::ContactMembershipService
  attr_reader :company

  def initialize(company:)
    @company = company
  end

  def assign(contact:)
    ensure_same_account!(contact)

    contact.update!(company: company)
    company.record_activity_at!(contact.last_activity_at) if contact.last_activity_at.present?
  end

  def remove(contact:)
    ensure_same_account!(contact)

    contact.update!(company: nil)
  end

  private

  def ensure_same_account!(contact)
    return if contact.account_id == company.account_id

    raise ActiveRecord::RecordNotFound
  end
end
