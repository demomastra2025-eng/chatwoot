# Contacts for the "Contact" condition picker of the automation rule form. Two uses, both limited to the account:
# - a page of contacts found by text (name, e-mail, phone typed in any format, identifier), the most recently active
#   first, so the picker works with any number of contacts;
# - the contacts behind the ids saved in a rule, so the form can show their names; an id missing from the answer
#   belongs to a deleted contact.
class AutomationRules::ContactOptionsService
  PER_PAGE = 20
  LOOKUP_LIMIT = 100

  def initialize(account:, query: nil, ids: nil, page: 1)
    @account = account
    @query = query.to_s.strip
    @ids = AutomationRules::ContactCondition.normalize_ids(ids).first(LOOKUP_LIMIT)
    @page = [page.to_i, 1].max
  end

  def perform
    ids.present? ? lookup : search
  end

  private

  attr_reader :account, :query, :ids, :page

  def lookup
    contacts = account.contacts.where(id: ids).order(:id).to_a
    result(contacts, has_more: false)
  end

  def search
    scope = account.contacts
    scope = Search::ContactQuery.new(query, identifier_case_sensitive: true).apply(scope) if query.present?
    rows = scope.order(Arel.sql('contacts.last_activity_at DESC NULLS LAST'), id: :desc)
                .offset((page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a

    result(rows.first(PER_PAGE), has_more: rows.size > PER_PAGE)
  end

  def result(contacts, has_more:)
    {
      payload: contacts.map { |contact| option_for(contact) },
      meta: { has_more: has_more, current_page: page }
    }
  end

  def option_for(contact)
    { id: contact.id, name: contact.name, phone_number: contact.phone_number.presence, email: contact.email.presence }
  end
end
