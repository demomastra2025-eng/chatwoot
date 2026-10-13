# The "Contact" condition of an automation rule: a rule can be limited to chosen contacts ("is") or skip them
# ("is not"), for example to never message a family or a test number. The values are contact ids of the rule's
# account, kept as a list of positive integers. It exists for the events that have a contact: conversation and
# message events (the conversation contact), appointment events (the booking contact and the patient card) and deal
# and task events (the contacts of the deal).
class AutomationRules::ContactCondition
  KEY = 'contact_id'.freeze
  OPERATORS = %w[equal_to not_equal_to].freeze
  MAX_VALUES = 1000
  MAX_ID = (2**63) - 1
  ID_PATTERN = /\A[1-9]\d*\z/

  # A contact id sent as an integer or as a string of digits; no floats, signs or nested values.
  def self.normalize_id(value)
    id = case value
         when Integer then value
         when String then value.to_i if value.match?(ID_PATTERN)
         end
    id if id&.positive? && id <= MAX_ID
  end

  def self.normalize_ids(values)
    Array.wrap(values).filter_map { |value| normalize_id(value) }.uniq
  end

  # The values of a condition as saved: a list of 1..MAX_VALUES contact ids.
  def self.ids_well_formed?(values)
    values.is_a?(Array) && values.size.between?(1, MAX_VALUES) && values.all? { |value| normalize_id(value) }
  end

  # A custom attribute that happens to be called "contact_id" keeps working as a custom attribute.
  def self.contact_condition?(condition)
    condition.respond_to?(:[]) && condition['attribute_key'].to_s == KEY && condition['custom_attribute_type'].blank?
  end

  # For conversation and message events: the SQL of the condition and its bind values. The query joins `contacts` on
  # the conversation contact. Only contacts of the rule's account count, so an id of another account in the list never
  # matches anything, and a conversation without a contact is not on the list. A list that cannot be read matches
  # nothing, so a broken rule never reaches a contact it should have skipped.
  def self.conversation_sql(operator, values, query_operator, index, account_id)
    ids = normalize_ids(values)
    return [" 1=0 #{query_operator} ", {}] if ids.blank? || OPERATORS.exclude?(operator)

    listed = "(contacts.account_id = :account_#{index} AND contacts.id IN (:value_#{index}))"
    sql = operator == 'equal_to' ? listed : "NOT COALESCE(#{listed}, FALSE)"
    [" #{sql} #{query_operator} ", { "account_#{index}" => account_id, "value_#{index}" => ids }]
  end

  # For events whose contacts are known in memory (appointments). A contact of the event that is on the list makes
  # "is" true and "is not" false; an event without any contact is not on the list.
  def self.matches?(operator, listed_ids, event_contact_ids)
    return false if listed_ids.blank?

    listed = listed_ids.intersect?(event_contact_ids.compact)
    { 'equal_to' => listed, 'not_equal_to' => !listed }.fetch(operator.to_s, false)
  end

  # The values with one contact id replaced by another (an id that ends up twice stays once). Values without the id stay
  # as they are.
  def self.replace_id(values, from, to)
    values = Array(values)
    return values unless values.any? { |value| normalize_id(value) == from }

    values.map { |value| normalize_id(value) == from ? to : value }.uniq { |value| normalize_id(value) || value }
  end

  # The contacts an automation record involves, as ids: the conversation contact; the booking contact and the patient
  # card of an appointment; every contact linked to a deal, and the contacts of the deal a task belongs to.
  def self.contact_ids_of(record)
    ids = case record
          when ::Crm::Deal then deal_contact_ids(record)
          when ::Crm::Task then record.deal.present? ? deal_contact_ids(record.deal) : []
          else [record.try(:contact_id), record.try(:patient_contact_id)]
          end
    ids.compact.uniq
  end

  def self.deal_contact_ids(deal)
    ::Crm::DealContact.where(account_id: deal.account_id, deal_id: deal.id).pluck(:contact_id)
  end
  private_class_method :deal_contact_ids

  # True when no way of passing the conditions is left for these contacts: every OR group of the rule has an "is not"
  # Contact condition that lists one of them. The other conditions do not matter then, so the answer holds whatever the
  # event looks like. This is the "never message this person" check that touches scheduled earlier are held to again
  # when they are about to go out. An "is" list narrows who the rule fires for and is only judged when the event fires.
  def self.excludes?(conditions, event_contact_ids)
    contact_ids = Array(event_contact_ids).compact
    return false if contact_ids.blank?

    groups = condition_groups(conditions)
    groups.present? && groups.all? { |group| group.any? { |condition| excluding_condition?(condition, contact_ids) } }
  end

  # The "is not" lists of the conditions, for a quick "is anyone excluded at all?" check.
  def self.excluded_ids(conditions)
    Array(conditions).select { |condition| excluding_condition?(condition) }
                     .flat_map { |condition| normalize_ids(condition['values']) }.uniq
  end

  # The conditions split the way every condition service reads them: "A AND B OR C" is [[A, B], [C]].
  def self.condition_groups(conditions)
    groups = [[]]
    Array(conditions).each do |condition|
      groups.last << condition
      groups << [] if condition['query_operator'].to_s.casecmp('OR').zero?
    end
    groups.reject(&:blank?)
  end
  private_class_method :condition_groups

  def self.excluding_condition?(condition, contact_ids = nil)
    return false unless contact_condition?(condition) && condition['filter_operator'].to_s == 'not_equal_to'

    listed_ids = normalize_ids(condition['values'])
    contact_ids.nil? ? listed_ids.present? : listed_ids.intersect?(contact_ids)
  end
  private_class_method :excluding_condition?
end
