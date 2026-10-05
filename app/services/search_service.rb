class SearchService
  MESSAGES_PER_PAGE = 15
  MESSAGES_LOOKBACK = 3.months
  # The English whole-word matching of the full-text index (search_with_gin) is the long-standing way to search text in
  # Latin script; it is kept next to the literal search, see #message_matcher.
  ENGLISH_MESSAGE_SQL = "to_tsvector('english'::regconfig, COALESCE(messages.content, '')) @@ to_tsquery('english'::regconfig, ?)".freeze
  # Latin text shorter than this keeps ONLY the English whole-word matching ("the" is a stop word and finds nothing, it
  # does not find "together"); longer Latin text and Cyrillic text of 3 characters or more are also searched literally.
  LITERAL_LATIN_MIN_LENGTH = 4

  pattr_initialize [:current_user!, :current_account!, :params!, :search_type!]

  def account_user
    @account_user ||= current_account.account_users.find_by(user: current_user)
  end

  # True when the search of message text was cancelled by its time limit and the page may be incomplete.
  def messages_partial?
    @messages_partial.present?
  end

  def perform
    case search_type
    when 'Message'
      { messages: filter_messages }
    when 'Conversation'
      { conversations: filter_conversations }
    when 'Contact'
      { contacts: filter_contacts }
    when 'Article'
      { articles: filter_articles }
    else
      { contacts: filter_contacts, messages: filter_messages, conversations: filter_conversations, articles: filter_articles }
    end
  end

  private

  def accessable_inbox_ids
    @accessable_inbox_ids ||= @current_user.assigned_inboxes.pluck(:id)
  end

  # The typed text without NUL bytes, invisible marks and exotic spaces, see Search::QueryText.
  def search_query
    @search_query ||= Search::QueryText.clean(params[:q])
  end

  def contact_query
    @contact_query ||= Search::ContactQuery.new(search_query)
  end

  def access_scope
    @access_scope ||= Search::AccessScope.new(account: current_account, user: current_user)
  end

  def filter_conversations
    # Only the conversations the user may OPEN (a custom role opens fewer than its inboxes), not just those of his inboxes.
    conversations_query = access_scope.conversations.where(inbox_id: accessable_inbox_ids)
                                         .joins('INNER JOIN contacts ON conversations.contact_id = contacts.id')
                                         .where(conversation_search_condition)

    if current_account.feature_enabled?('advanced_search')
      conversations_query = apply_time_filter(conversations_query,
                                              'conversations.last_activity_at')
    end

    @conversations = conversations_query.order('conversations.created_at DESC')
                                        .page(params[:page])
                                        .per(15)
  end

  def filter_messages
    @messages = if use_gin_search
                  filter_messages_with_gin
                elsif should_run_advanced_search?
                  advanced_search_with_fallback
                else
                  filter_messages_with_like
                end
  end

  def advanced_search_with_fallback
    advanced_search
  rescue Faraday::ConnectionFailed, Searchkick::Error, Elasticsearch::Transport::Transport::Error => e
    Rails.logger.warn("Elasticsearch unavailable, falling back to SQL search: #{e.message}")
    use_gin_search ? filter_messages_with_gin : filter_messages_with_like
  end

  def should_run_advanced_search?
    ChatwootApp.advanced_search_allowed? && current_account.feature_enabled?('advanced_search')
  end

  def advanced_search; end

  def filter_messages_with_gin
    base_query = apply_message_filters(message_base_query)
    return base_query.reorder('created_at DESC').page(params[:page]).per(MESSAGES_PER_PAGE) if search_query.blank?

    matcher = message_matcher
    return base_query.none if matcher.nil?
    return newest_message_matches(base_query, matcher) if literal_message_search?

    base_query.where(matcher).reorder('created_at DESC').page(params[:page]).per(MESSAGES_PER_PAGE)
  end

  # Without the full-text index the text is searched literally in every script, from 3 characters.
  def filter_messages_with_like
    base_query = apply_message_filters(message_base_query)
    return base_query.where('messages.content ILIKE ?', '%%').reorder('created_at DESC').page(params[:page]).per(MESSAGES_PER_PAGE) if search_query.blank?
    return base_query.none unless literal_message_query.searchable?

    newest_message_matches(base_query, literal_message_query.condition)
  end

  def message_base_query
    query = Messages::TimelineVisibility.without_captain_tool_activity(
      current_account.messages.where('created_at >= ?', MESSAGES_LOOKBACK.ago)
    )
    query = query.where(inbox_id: accessable_inbox_ids) unless should_skip_inbox_filtering?
    # A custom role opens fewer conversations than its inboxes hold: the text of a conversation it cannot open is not found.
    query = query.where(conversation_id: access_scope.conversations.select(:id)) if access_scope.restricted?
    query
  end

  def literal_message_query
    @literal_message_query ||= Search::MessageQuery.new(search_query)
  end

  # Text with a letter outside ASCII (Russian, Kazakh ...) is matched literally: the typed text has to occur in the
  # message, in any case, with е and ё interchangeable, no word forms (see Search::MessageQuery). Latin text keeps the
  # English whole-word matching of the full-text index and, from LITERAL_LATIN_MIN_LENGTH characters, is also matched
  # literally. Text of 1-2 non-Latin letters has no literal search (it would match nearly every message), only the whole
  # word of the full-text index.
  def literal_message_search?
    return false unless literal_message_query.searchable?

    !search_query.ascii_only? || search_query.length >= LITERAL_LATIN_MIN_LENGTH
  end

  def english_message_search?
    search_query.ascii_only? || !literal_message_search?
  end

  def message_matcher
    english = english_message_condition if english_message_search?
    literal = literal_message_query.condition if literal_message_search?
    [english, literal].compact.reduce { |combined, condition| Arel::Nodes::Grouping.new(combined).or(condition) }
  end

  # Only words are put into the tsquery: an operator or a bracket typed by a person would be a syntax error (HTTP 500).
  def english_message_condition
    words = search_query.split.map { |word| word.gsub(/[^[:alnum:]_]/, '') }.reject(&:empty?)
    return if words.empty?

    # This does entire phrase matching using the phrase distance operator, as before.
    Arel::Nodes::Grouping.new(Arel.sql(ActiveRecord::Base.sanitize_sql_array([ENGLISH_MESSAGE_SQL, words.join(' <-> ')])))
  end

  # The newest matches are chosen by Search::MessageQuery, not by the planner; the page is then read by id, so that the
  # relation still carries the whole condition.
  def newest_message_matches(base_query, matcher)
    page = [params[:page].to_i, 1].max
    result = literal_message_query.newest(base_query, match: matcher, limit: MESSAGES_PER_PAGE, offset: (page - 1) * MESSAGES_PER_PAGE)
    @messages_partial = result.partial
    base_query.where(matcher).where(id: result.rows.map(&:first)).reorder('messages.created_at DESC, messages.id DESC')
  end

  def apply_message_filters(query)
    return query unless current_account.feature_enabled?('advanced_search')

    query = apply_time_filter(query, 'messages.created_at')
    query = apply_sender_filter(query)
    apply_inbox_id_filter(query)
  end

  def apply_sender_filter(query)
    sender_type, sender_id = parse_from_param(params[:from])
    return query unless sender_type && sender_id

    query.where(sender_type: sender_type, sender_id: sender_id)
  end

  def parse_from_param(from_param)
    return [nil, nil] unless from_param&.match?(/\A(contact|agent):\d+\z/)

    type, id = from_param.split(':')
    sender_type = type == 'agent' ? 'User' : 'Contact'
    [sender_type, id.to_i]
  end

  def apply_inbox_id_filter(query)
    return query if params[:inbox_id].blank?

    inbox_id = params[:inbox_id].to_i
    return query if inbox_id.zero?
    return query unless validate_inbox_access(inbox_id)

    query.where(inbox_id: inbox_id)
  end

  def validate_inbox_access(inbox_id)
    return true if should_skip_inbox_filtering?

    accessable_inbox_ids.include?(inbox_id)
  end

  def should_skip_inbox_filtering?
    account_user.administrator? || user_has_access_to_all_inboxes?
  end

  def user_has_access_to_all_inboxes?
    accessable_inbox_ids.sort == current_account.inboxes.pluck(:id).sort
  end

  def use_gin_search
    current_account.feature_enabled?('search_with_gin')
  end

  def filter_contacts
    contacts_query = contact_query.apply(current_account.contacts)

    contacts_query = apply_time_filter(contacts_query, 'last_activity_at') if current_account.feature_enabled?('advanced_search')

    @contacts = contacts_query.resolved_contacts(
      use_crm_v2: current_account.feature_enabled?('crm_v2')
    ).order_on_last_activity_at('desc').page(params[:page]).per(15)
  end

  def filter_articles
    articles_query = current_account.articles.text_search(search_query)
    articles_query = apply_time_filter(articles_query, 'updated_at') if current_account.feature_enabled?('advanced_search')

    @articles = articles_query.page(params[:page]).per(15)
  end

  def apply_time_filter(query, column_name)
    return query if params[:since].blank? && params[:until].blank?

    query = query.where("#{column_name} >= ?", cap_since_time(params[:since])) if params[:since].present?
    query = query.where("#{column_name} <= ?", cap_until_time(params[:until])) if params[:until].present?
    query
  end

  def cap_since_time(since_param)
    max_lookback = 90.days.ago
    requested_time = Time.zone.at(since_param.to_i)

    # Silently cap to max_lookback if requested time is too far back
    [requested_time, max_lookback].max
  end

  def cap_until_time(until_param)
    max_future = 90.days.from_now
    requested_time = Time.zone.at(until_param.to_i)

    [requested_time, max_future].min
  end

  # The display id, the contact (name, e-mail, phone number in any format, identifier) and the text of the conversation's
  # messages of the last three months (the newest MESSAGE_LIMIT matches, found literally and only in conversations the
  # user may open, see Search::ConversationLookup).
  def conversation_search_condition
    display_id = Arel::Nodes::NamedFunction.new('CAST', [Conversation.arel_table[:display_id].as('text')])
    conditions = [display_id.matches(Search::QueryText.like_pattern(search_query), nil, false), contact_query.condition]
    message_conversation_ids = conversation_lookup.message_conversation_ids
    conditions << Conversation.arel_table[:id].in(message_conversation_ids) if message_conversation_ids.any?
    conditions.reduce { |combined, condition| combined.or(condition) }
  end

  def conversation_lookup
    @conversation_lookup ||= Search::ConversationLookup.new(
      account: current_account, raw_query: search_query, scope: access_scope.conversations,
      inbox_ids: should_skip_inbox_filtering? ? nil : accessable_inbox_ids, restricted: access_scope.restricted?,
      message_since: MESSAGES_LOOKBACK.ago
    )
  end
end

SearchService.prepend_mod_with('SearchService')
