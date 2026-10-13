# The "Contact" condition of an automation rule: a rule can be limited to chosen contacts ("is") or skip them
# ("is not"), for example to never message a family or a test number. The values are contact ids of the rule's
# account, kept as a list of positive integers. It exists for the events that have a contact: conversation and
# message events (the conversation contact) and appointment events (the booking contact and the patient card).
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
end
