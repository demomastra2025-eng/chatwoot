# frozen_string_literal: true

module Filters::MetaAdReferralFilter
  TRUE_VALUES = [true, 'true', 1, '1'].freeze
  FALSE_VALUES = [false, 'false', 0, '0'].freeze
  PRESENCE_OPERATORS = %w[equal_to not_equal_to is_present is_not_present].freeze
  SOURCE_OPERATORS = %w[equal_to not_equal_to contains does_not_contain is_present is_not_present].freeze
  NON_BLANK_SOURCE_SQL = "(COALESCE(mar.source_id, '') <> '' OR COALESCE(mar.ad_id, '') <> '' OR COALESCE(mar.headline, '') <> '')"

  private

  def meta_ad_referral_filter_query(query_hash, current_index, table_name: filter_config[:table_name])
    raw_hash = query_hash.respond_to?(:to_unsafe_h) ? query_hash.to_unsafe_h : query_hash.to_h
    condition = raw_hash.with_indifferent_access
    @filter_values["meta_ad_account_id_#{current_index}"] = @account.id
    predicate = if condition[:attribute_key].to_s == 'meta_ad_source_id'
                  meta_ad_source_predicate_sql(condition, current_index, table_name)
                else
                  meta_ad_presence_predicate_sql(condition, current_index, table_name)
                end
    "#{predicate} #{condition[:query_operator]}".strip
  end

  def meta_ad_presence_predicate_sql(condition, current_index, table_name)
    exists_sql = meta_ad_exists_sql(current_index, table_name: table_name)
    case condition[:filter_operator].to_s
    when 'is_present' then exists_sql
    when 'is_not_present' then "NOT #{exists_sql}"
    when 'equal_to', 'not_equal_to' then meta_ad_boolean_predicate_sql(condition, exists_sql)
    else
      raise CustomExceptions::CustomFilter::InvalidOperator.new(attribute_name: condition[:attribute_key], allowed_keys: PRESENCE_OPERATORS)
    end
  end

  def meta_ad_boolean_predicate_sql(condition, exists_sql)
    booleans = parse_meta_ad_booleans(condition[:values], condition[:attribute_key])
    negate = condition[:filter_operator].to_s == 'not_equal_to'
    return negate ? '(1 = 0)' : '(1 = 1)' if booleans.length == 2

    want_present = negate ? !booleans.first : booleans.first
    want_present ? exists_sql : "NOT #{exists_sql}"
  end

  def parse_meta_ad_booleans(raw_values, attribute_key)
    values = raw_values.is_a?(Array) ? raw_values : [raw_values].compact
    raise CustomExceptions::CustomFilter::InvalidValue.new(attribute_name: attribute_key) if values.empty?

    values.map do |val|
      normalized = val.is_a?(String) ? val.strip.downcase : val
      next true if TRUE_VALUES.include?(normalized)
      next false if FALSE_VALUES.include?(normalized)

      raise CustomExceptions::CustomFilter::InvalidValue.new(attribute_name: attribute_key)
    end.uniq
  end

  def meta_ad_source_predicate_sql(condition, current_index, table_name)
    op = condition[:filter_operator].to_s
    extra = case op
            when 'is_present', 'is_not_present' then NON_BLANK_SOURCE_SQL
            when 'equal_to', 'not_equal_to' then meta_ad_exact_match_sql(condition, current_index)
            when 'contains', 'does_not_contain' then meta_ad_like_match_sql(condition, current_index)
            else raise CustomExceptions::CustomFilter::InvalidOperator.new(attribute_name: condition[:attribute_key], allowed_keys: SOURCE_OPERATORS)
            end
    sql = meta_ad_exists_sql(current_index, table_name: table_name, extra_sql: extra)
    %w[is_not_present not_equal_to does_not_contain].include?(op) ? "NOT #{sql}" : sql
  end

  def meta_ad_exact_match_sql(condition, current_index)
    values = normalized_meta_ad_text_values(condition)
    exact_key = "meta_ad_exact_#{current_index}"
    ilike_key = "meta_ad_exact_ilike_#{current_index}"
    @filter_values[exact_key] = values
    @filter_values[ilike_key] = values.map { |val| ActiveRecord::Base.sanitize_sql_like(val) }
    "(mar.source_id IN (:#{exact_key}) OR mar.ad_id IN (:#{exact_key}) OR COALESCE(mar.headline, '') ILIKE ANY (ARRAY[:#{ilike_key}]))"
  end

  def meta_ad_like_match_sql(condition, current_index)
    values = normalized_meta_ad_text_values(condition)
    like_key = "meta_ad_like_#{current_index}"
    @filter_values[like_key] = values.map { |val| "%#{ActiveRecord::Base.sanitize_sql_like(val)}%" }
    "(COALESCE(mar.source_id, '') ILIKE ANY (ARRAY[:#{like_key}]) " \
      "OR COALESCE(mar.ad_id, '') ILIKE ANY (ARRAY[:#{like_key}]) OR COALESCE(mar.headline, '') ILIKE ANY (ARRAY[:#{like_key}]))"
  end

  def normalized_meta_ad_text_values(condition)
    raw = condition[:values]
    values = (raw.is_a?(Array) ? raw : [raw]).map { |val| val.to_s.strip }.reject(&:blank?)
    raise CustomExceptions::CustomFilter::InvalidValue.new(attribute_name: condition[:attribute_key]) if values.empty?

    values
  end

  def meta_ad_exists_sql(current_index, table_name:, extra_sql: nil)
    clauses = [meta_ad_target_join_sql(current_index, table_name), extra_sql].compact.join(' AND ')
    "EXISTS (SELECT 1 FROM meta_ad_referrals mar WHERE #{clauses})"
  end

  def meta_ad_target_join_sql(current_index, table_name)
    account_bind = ":meta_ad_account_id_#{current_index}"
    return "mar.account_id = #{account_bind} AND mar.contact_id = contacts.id" if table_name.to_s == 'contacts'
    return "mar.account_id = #{account_bind} AND (#{meta_ad_thread_conversation_match_sql(account_bind)})" if match_thread_meta_ad_referrals?

    "mar.account_id = #{account_bind} AND mar.conversation_id = conversations.id"
  end

  def meta_ad_thread_conversation_match_sql(account_bind)
    'mar.conversation_id = conversations.id OR EXISTS (' \
      'SELECT 1 FROM communication_thread_conversations ctc ' \
      "WHERE ctc.account_id = #{account_bind} AND ctc.conversation_id = conversations.id AND (" \
      'mar.communication_thread_id = ctc.communication_thread_id OR mar.conversation_id IN (' \
      'SELECT ctc_peer.conversation_id FROM communication_thread_conversations ctc_peer ' \
      "WHERE ctc_peer.account_id = #{account_bind} AND ctc_peer.communication_thread_id = ctc.communication_thread_id)))"
  end

  def match_thread_meta_ad_referrals?
    false
  end
end
