class Whatsapp::CoexistenceWebhookBatcher
  HISTORY_MESSAGES_PER_BATCH = 25
  CONTACT_EVENTS_PER_BATCH = 50
  MEDIA_MESSAGES_PER_BATCH = 1

  def initialize(field, value)
    @field = field
    @value = value.with_indifferent_access
  end

  def perform
    case @field
    when 'history'
      history_batches
    when 'smb_app_state_sync'
      state_sync_batches
    else
      [@value]
    end
  end

  private

  def history_batches
    batches = Array(@value[:history]).flat_map { |history| batches_for_history_entry(history) }
    batches.concat(top_level_message_batches)
    batches.concat(top_level_message_batches(:message_echoes))
    batches.presence || [@value]
  end

  def batches_for_history_entry(raw_history)
    history = raw_history.to_h.with_indifferent_access
    pieces = history_pieces(history)
    pieces.each_with_index.map do |piece, index|
      piece = piece.except(:metadata) unless index == pieces.length - 1
      history_value(piece)
    end
  end

  def history_pieces(history)
    threads = Array(history[:threads])
    return [history] if history[:errors].present? || threads.empty?

    threads.flat_map do |raw_thread|
      thread = raw_thread.to_h.with_indifferent_access
      messages = Array(thread[:messages])
      next [history.merge(threads: [thread])] if messages.empty?

      messages.each_slice(HISTORY_MESSAGES_PER_BATCH).map do |slice|
        history.merge(threads: [thread.merge(messages: slice)])
      end
    end
  end

  def history_value(history)
    history_base.merge(history: [history])
  end

  def top_level_message_batches(key = :messages)
    Array(@value[key]).each_slice(MEDIA_MESSAGES_PER_BATCH).map do |slice|
      history_base.merge(key => slice)
    end
  end

  def history_base
    @history_base ||= @value.except(:history, :messages, :message_echoes).deep_dup
  end

  def state_sync_batches
    entries = Array(@value[:state_sync])
    return [@value] if entries.empty?

    entries.each_slice(CONTACT_EVENTS_PER_BATCH).map do |slice|
      @value.except(:state_sync).merge(state_sync: slice)
    end
  end
end
