# Labels belong to a person. The contact card and every conversation of the person (its communication thread) carry the
# same labels, and every reader takes the union of them (union_for, Labels::ConversationScope). This service is the one
# place that changes them: the dialog and the contact card, automation rules, macros, the AI tools, the phone labels of
# WhatsApp, bulk actions, the widget, the auto-resolve label and the contact merge all call it with a delta.
#
#   Labels::UnifiedAssignmentService.add(contact: contact, labels: ['vip'], conversation: conversation)
#   Labels::UnifiedAssignmentService.remove(contact: contact, labels: ['vip'], conversation: conversation)
#
# A call is one change of the person, however many conversations it touches:
# - it writes the contact and EVERY conversation of the contact, not only the ones the caller may open, because the
#   label belongs to the person (a removal that skipped a hidden channel would bring the label back for a colleague);
# - the first conversation whose labels change (the source, then the last active ones) reports the change: it fires the
#   usual conversation events and writes the one activity message. The others are saved without events and without
#   activity and carry the same communication_thread_event_id, like the other thread-wide writes
#   (CommunicationThreads::UpdateService, Contacts::OwnerSyncService), so a rule or a webhook sees one change, not N;
# - a record whose labels already are what is asked is not saved at all;
# - only the given labels are touched. A list the client has not seen (a stale one) cannot erase a label, which is why
#   callers send add / remove and not the whole list (see delta_from_params for the older clients that still do).
#
# silent: true is for system rewrites (contact merge, the one-time backfill): nothing is dispatched, no activity message.
class Labels::UnifiedAssignmentService
  REALTIME_SOURCE_EVENT = 'conversation.updated'.freeze

  class << self
    def union_for(contact:, conversations:)
      labels = []
      labels.concat(contact.label_list) if contact.present?
      Array(conversations).compact.each { |conversation| labels.concat(conversation.label_list) }
      normalize(labels)
    end

    def normalize(labels)
      Array(labels).flatten.compact.map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    # Labels of the whole person in one query: the contact first, then every conversation of the contact.
    def person_labels(contact_id:, account_id:)
      return [] if contact_id.blank?

      taggings = ActsAsTaggableOn::Tagging.where(context: 'labels', tagger_id: nil)
      conversation_ids = Conversation.where(account_id: account_id, contact_id: contact_id).select(:id)
      scope = taggings.where(taggable_type: 'Contact', taggable_id: contact_id)
                      .or(taggings.where(taggable_type: 'Conversation', taggable_id: conversation_ids))
      order = Arel.sql("CASE taggings.taggable_type WHEN 'Contact' THEN 0 ELSE 1 END")
      normalize(scope.joins(:tag).order(order, 'taggings.id').pluck('tags.name'))
    end

    def add(contact:, labels:, **options)
      new(contact: contact, add: labels, **options).perform
    end

    def remove(contact:, labels:, **options)
      new(contact: contact, remove: labels, **options).perform
    end

    # Writes the union of everything the person carries (plus extra_labels) to the contact and to every conversation.
    # Used where two cards become one and by Labels::PersonUnionBackfill.
    def unify(contact:, extra_labels: [])
      labels = person_labels(contact_id: contact.id, account_id: contact.account_id) + Array(extra_labels)
      add(contact: contact, labels: labels, silent: true)
    end

    # Reads a label change from request params into [add, remove].
    # add / remove are taken as they are. A whole list (older clients) is turned into a delta against visible_labels, the
    # labels that client could have seen: it can add what is missing and remove what it saw and left out, but it can never
    # remove a label that lives where it could not look (for the dialog that is the contact card).
    def delta_from_params(params, visible_labels:)
      return [normalize(params[:add]), normalize(params[:remove])] if params.key?(:add) || params.key?(:remove)

      wanted = normalize(params[:labels])
      wanted_keys = wanted.map(&:downcase)
      [wanted, normalize(visible_labels).reject { |label| wanted_keys.include?(label.downcase) }]
    end
  end

  def initialize(contact:, conversation: nil, add: nil, remove: nil, silent: false)
    @contact = contact
    @source = conversation
    @source_id = conversation&.id
    @add = self.class.normalize(add).uniq(&:downcase)
    @remove_keys = self.class.normalize(remove).map(&:downcase)
    @silent = silent
  end

  def perform
    return [] if contact.blank?
    return person_labels if @add.empty? && @remove_keys.empty?

    @event_id = SecureRandom.uuid
    @reported = false
    ActiveRecord::Base.transaction do
      @person = Contact.lock.find_by(id: contact.id, account_id: contact.account_id)
      next if @person.blank?

      write_contact
      @conversations = person_conversations
      @conversations.each { |conversation| write_conversation(conversation) }
    end
    refresh_thread_realtime
    forget_cached_labels
    person_labels
  end

  private

  attr_reader :contact, :silent

  def person_labels
    self.class.person_labels(contact_id: contact.id, account_id: contact.account_id)
  end

  def person_conversations
    ordered = Conversation.where(account_id: @person.account_id, contact_id: @person.id)
                          .order(Arel.sql('conversations.last_activity_at DESC NULLS LAST'), id: :desc).to_a
    source = ordered.find { |conversation| conversation.id == @source_id }
    source ? [source] + (ordered - [source]) : ordered
  end

  def write_contact
    labels = changed_labels(@person)
    return if labels.nil?

    @person.skip_runtime_events = true if silent
    @person.update_labels(labels)
    @contact_changed = true
  end

  def write_conversation(conversation)
    labels = changed_labels(conversation)
    return if labels.nil?

    conversation.communication_thread_event_id = @event_id
    quiet_conversation(conversation) if silent || @reported
    @reported = true
    conversation.update_labels(labels)
  end

  # The records after the first one are saved the way the rest of the thread-wide writes do it: no events, no activity,
  # no thread refresh (labels are not part of the thread aggregates).
  def quiet_conversation(conversation)
    conversation.skip_runtime_events = true
    conversation.skip_activity_messages = true
    conversation.skip_communication_thread_refresh = true
  end

  # The new labels of the record, or nil when they would not change.
  def changed_labels(record)
    current = record.label_list.to_a
    kept = current.reject { |label| @remove_keys.include?(label.downcase) }
    present = kept.map(&:downcase)
    updated = kept + @add.reject { |label| present.include?(label.downcase) }
    updated == current ? nil : updated
  end

  # The contact and the conversation the caller holds may have read their label list before this change. Saved later, that
  # copy would be written back over it (ActsAsTaggable keeps it until the record is reloaded), so drop it the same way.
  def forget_cached_labels
    [contact, @source].compact.each do |record|
      %i[@label_list @all_label_list].each do |name|
        record.remove_instance_variable(name) if record.instance_variable_defined?(name)
      end
    end
  end

  # A label that lives only on the contact card changes the person's labels without saving any conversation, so no
  # conversation event would tell the open dialogs. One thread update does.
  def refresh_thread_realtime
    return if silent || @reported || !@contact_changed

    source = @conversations&.first
    return if source.blank? || !@person.account.feature_enabled?('communication_threads')

    thread = source.communication_thread
    return if thread.blank?

    CommunicationThreads::RealtimeUpdateJob.perform_later(
      communication_thread_id: thread.id, source_conversation_id: source.id,
      source_event: REALTIME_SOURCE_EVENT, performer_id: Current.user&.id
    )
  end
end
