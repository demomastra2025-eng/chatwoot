# LITERAL search of the text of messages. The typed text has to occur in the message exactly as typed: anywhere in the
# text (a substring, so a word start, a word ending and a part of a word all count), ignoring the case, with "е" and
# "ё" interchangeable. There is no stemming and no word forms: "записаться" does NOT find "записали".
#
# The condition is a plain ILIKE '%text%' (or a case-insensitive regular expression with [её] when the text has е or ё),
# which PostgreSQL answers from the pg_trgm index on messages.content (index_messages_on_content, db/migrate/
# 20230426130150_init_schema.rb). That index is not scoped to an account, so which of the two plans the planner picks
# decides the speed, and it often picks the wrong one: for a word that is common in other accounts but rare in this one
# it walks the whole look-back window of the account and evaluates the text of every message (measured: 0.5 s on 114,000
# messages, many seconds on a cold cache). The newest matches are therefore fetched in two steps whose plans are fixed
# here and do not depend on the planner's guess:
#   1. the RECENT_ROWS newest messages of the account are read in order and tested one by one (a sub-select with its own
#      LIMIT cannot be flattened by the planner). A word that occurs in more than about 1 message in 250 fills the page
#      from them in a few milliseconds, and an account that has fewer messages than that is searched completely;
#   2. when the page is still not full, the whole window is searched with the trigram index and nothing else
#      (plain index scans are switched off for this one statement, bitmap plans stay), which costs about the number of
#      matches of the word in all accounts and is fast for a word that is rare.
# Both steps run under their own statement timeout (SEARCH_MESSAGE_TIMEOUT, 3 seconds); a step that is cancelled leaves
# what was found so far and the result says it is partial, so that the caller can tell the person to be more precise.
class Search::MessageQuery
  MIN_LENGTH = 3
  RECENT_ROWS = 4000
  # Newest matches that can be paged to; a person who wants the 500th match of a word has to make the word more precise.
  MAX_RESULTS = 500
  TIMEOUT = ENV.fetch('SEARCH_MESSAGE_TIMEOUT', '3s')
  # How far back the text of messages is searched by the conversation list search (the global search has its own limit).
  LOOKBACK_DAYS = ENV.fetch('SEARCH_MESSAGE_LOOKBACK_DAYS', 365).to_i

  Result = Struct.new(:rows, :partial) # rows: [[message id, conversation id], ...], newest first

  def self.lookback_since
    LOOKBACK_DAYS.days.ago
  end

  attr_reader :text

  def initialize(raw_query)
    @text = Search::QueryText.clean(raw_query)
  end

  def searchable?
    text.length >= MIN_LENGTH
  end

  # The literal condition, as an Arel node on messages.content.
  def condition(table = Message.arel_table)
    if Search::QueryText.yo?(text)
      table[:content].matches_regexp(Search::QueryText.yo_regexp(text), false)
    else
      table[:content].matches(Search::QueryText.like_pattern(text), nil, false)
    end
  end

  # The newest messages of `base` (messages already limited to an account, inboxes, the look-back and so on) that match
  # `match` (the literal condition unless the caller combines it with another), `limit` of them after `offset`.
  def newest(base, limit:, offset: 0, match: condition)
    needed = offset + limit
    return Result.new([], false) if !searchable? || offset >= MAX_RESULTS

    needed = [needed, MAX_RESULTS].min
    rows = []
    partial = false
    begin
      within_statement_timeout do
        rows = recent_rows(base, match, needed)
        rows = indexed_rows(base, match, needed) if rows.size < needed
      end
    rescue ActiveRecord::QueryCanceled
      Rails.logger.warn('Message text search was cancelled by its time limit')
      partial = true
    end
    Result.new(rows.drop(offset).first(limit), partial)
  end

  private

  def recent_rows(base, match, needed)
    table = Message.arel_table
    recent = base.reorder(table[:created_at].desc, table[:id].desc).limit(RECENT_ROWS)
                 .select(:id, :conversation_id, :content, :created_at)
    ordered(Message.unscoped.from(recent, :messages).where(match), needed)
  end

  # A failed statement rolls the settings back with its savepoint, so they are put back only when it succeeded.
  def indexed_rows(base, match, needed)
    switch_plan_setting('enable_indexscan', 'off')
    ordered(base.where(match), needed).tap { switch_plan_setting('enable_indexscan', 'on') }
  end

  def ordered(relation, count)
    table = Message.arel_table
    relation.reorder(table[:created_at].desc, table[:id].desc).limit(count).pluck(:id, :conversation_id)
  end

  # set_config(..., true) lasts to the end of the enclosing transaction, so the previous timeout is put back by hand when
  # the block succeeds; when it fails the rollback of its savepoint takes the setting back.
  def within_statement_timeout
    ActiveRecord::Base.transaction(requires_new: true) do
      previous = ActiveRecord::Base.connection.select_value('SHOW statement_timeout')
      switch_plan_setting('statement_timeout', TIMEOUT)
      yield
      switch_plan_setting('statement_timeout', previous)
    end
  end

  def switch_plan_setting(name, value)
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT set_config(?, ?, true)', name, value]))
  end
end
