class Scheduling::AppointmentDialogContextLoader
  def initialize(appointments)
    @appointments = Array(appointments)
  end

  def perform
    return {} if appointments.empty?

    preload_direct_conversations
    @candidates = appointments.reject { |appointment| available_conversation?(appointment.conversation) }
    return {} if candidates.empty?

    load_dialog_records
    build_context
  end

  private

  attr_reader :appointments, :candidates, :contact_conversations, :primary_conversations, :selected_threads

  def build_context
    candidates.each_with_object({}) do |appointment, result|
      chat_conversation = chat_conversation_for(appointment)
      result[appointment.id] = {
        chat_conversation: chat_conversation,
        communication_thread: communication_thread_for(appointment, chat_conversation)
      }
    end
  end

  def chat_conversation_for(appointment)
    selected_thread = selected_threads[appointment]
    return primary_conversations[selected_thread.id] if selected_thread.present?

    contact_conversations[contact_key(appointment)]
  end

  def communication_thread_for(appointment, chat_conversation)
    selected_thread = selected_threads[appointment]
    return selected_thread if appointment.conversation.present? || chat_conversation.blank?

    chat_conversation.communication_thread
  end

  def available_conversation?(conversation)
    conversation&.inbox.present?
  end

  def contact_key(record)
    [record.account_id, record.contact_id]
  end

  def contact_keys(records)
    records.filter_map { |record| contact_key(record) if record.contact_id.present? }.uniq
  end

  def load_dialog_records
    contact_threads = latest_records_by_contact(
      CommunicationThread,
      candidates.select { |appointment| appointment.conversation.blank? }
    )
    @selected_threads = candidates.index_with do |appointment|
      appointment.conversation&.communication_thread || contact_threads[contact_key(appointment)]
    end
    @primary_conversations = primary_conversations_by_thread(selected_threads.values.compact)
    @contact_conversations = latest_records_by_contact(
      Conversation,
      candidates.select { |appointment| selected_threads[appointment].blank? },
      preload: [:inbox, :communication_thread]
    )
  end

  def latest_records_by_contact(model, appointment_records, preload: nil)
    keys = contact_keys(appointment_records)
    return {} if keys.empty?

    keys.group_by(&:first).each_with_object({}) do |(account_id, account_keys), result|
      contact_ids = account_keys.map(&:last)
      table_name = model.table_name
      scope = model
              .where(account_id: account_id, contact_id: contact_ids)
              .select("DISTINCT ON (#{table_name}.contact_id) #{table_name}.*")
              .order("#{table_name}.contact_id ASC, #{table_name}.last_activity_at DESC, #{table_name}.id DESC")
      scope = scope.preload(preload) if preload.present?
      scope.each { |record| result[[account_id, record.contact_id]] = record }
    end
  end

  def preload_direct_conversations
    ActiveRecord::Associations::Preloader.new(
      records: appointments,
      associations: { conversation: [:inbox, :communication_thread] }
    ).call
  end

  def primary_conversations_by_thread(threads)
    threads.group_by(&:account_id).each_with_object({}) do |(account_id, account_threads), result|
      CommunicationThreadConversation
        .where(account_id: account_id, communication_thread_id: account_threads.map(&:id))
        .preload(conversation: [:inbox, :communication_thread])
        .order(primary: :desc, id: :desc)
        .each do |link|
          result[link.communication_thread_id] ||= link.conversation
        end
    end
  end
end
