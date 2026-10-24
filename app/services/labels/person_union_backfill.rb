# One-time catch-up for labels written before every path went through Labels::UnifiedAssignmentService: the contact and
# every conversation of a person get the union of the labels the person carries (what the dialog already shows).
#
# It is a dry run unless apply: true. A dry run only counts: it reads the taggings and writes nothing. It reports numbers
# and never names a person, a label or a conversation.
#
#   Labels::PersonUnionBackfill.new(account_id: 1).perform                # counts only
#   Labels::PersonUnionBackfill.new(account_id: 1, apply: true).perform   # writes, quietly (no events, no activity)
#
# See lib/tasks/person_labels.rake.
class Labels::PersonUnionBackfill
  DEFAULT_BATCH_SIZE = 500

  def initialize(account_id: nil, apply: false, batch_size: DEFAULT_BATCH_SIZE)
    @account_id = account_id.presence
    @apply = apply
    @batch_size = [batch_size.to_i, 1].max
    @stats = Hash.new(0)
  end

  def perform
    labeled_contacts.in_batches(of: @batch_size) do |batch|
      plans = plan_batch(batch.pluck(:id))
      @stats[:people_scanned] += plans.size
      plans.each { |plan| count(plan) }
      apply_batch(plans) if @apply
    end
    report
  end

  private

  # People that have a label on the contact or on any of their conversations; only they can need a rewrite.
  def labeled_contacts
    labels = ActsAsTaggableOn::Tagging.where(context: 'labels', tagger_id: nil)
    on_contact = labels.where(taggable_type: 'Contact').select(:taggable_id)
    on_conversation = Conversation.where(id: labels.where(taggable_type: 'Conversation').select(:taggable_id)).select(:contact_id)
    scope = Contact.where(id: on_contact).or(Contact.where(id: on_conversation))
    @account_id ? scope.where(account_id: @account_id) : scope
  end

  # For every person of the batch: the union and what the contact and each conversation lack.
  def plan_batch(contact_ids)
    conversations = Conversation.where(contact_id: contact_ids).pluck(:id, :contact_id)
    contact_labels = names_by_record('Contact', contact_ids)
    conversation_labels = names_by_record('Conversation', conversations.map(&:first))
    conversations_by_contact = conversations.group_by(&:last)

    contact_ids.map do |contact_id|
      lists = conversations_by_contact.fetch(contact_id, []).map { |conversation_id, _| conversation_labels.fetch(conversation_id, []) }
      on_contact = contact_labels.fetch(contact_id, [])
      union = Labels::UnifiedAssignmentService.normalize(on_contact + lists.flatten)
      { contact_id: contact_id, contact_missing: union - on_contact, conversation_missing: lists.map { |labels| union - labels } }
    end
  end

  def count(plan)
    missing = plan[:conversation_missing].reject(&:empty?)
    return if plan[:contact_missing].empty? && missing.empty?

    @stats[:people_to_change] += 1
    @stats[:contacts_to_change] += 1 if plan[:contact_missing].any?
    @stats[:conversations_to_change] += missing.size
    @stats[:labels_to_write] += plan[:contact_missing].size + missing.sum(&:size)
  end

  def apply_batch(plans)
    plans.each do |plan|
      next if plan[:contact_missing].empty? && plan[:conversation_missing].all?(&:empty?)

      write_person(plan[:contact_id])
    end
  end

  def write_person(contact_id)
    contact = Contact.find_by(id: contact_id)
    return if contact.blank?

    Labels::UnifiedAssignmentService.unify(contact: contact)
    @stats[:people_written] += 1
  rescue StandardError => e
    @stats[:people_failed] += 1
    Rails.logger.warn("[Labels::PersonUnionBackfill] contact=#{contact_id} skipped: #{e.class}")
  end

  def names_by_record(record_type, ids)
    return {} if ids.empty?

    ActsAsTaggableOn::Tagging
      .joins(:tag)
      .where(taggable_type: record_type, taggable_id: ids, context: 'labels', tagger_id: nil)
      .order('taggings.id')
      .pluck(:taggable_id, 'tags.name')
      .group_by(&:first).transform_values { |rows| rows.map(&:second) }
  end

  def report
    { dry_run: !@apply, account_id: @account_id,
      people_scanned: @stats[:people_scanned], people_to_change: @stats[:people_to_change],
      contacts_to_change: @stats[:contacts_to_change], conversations_to_change: @stats[:conversations_to_change],
      labels_to_write: @stats[:labels_to_write], people_written: @stats[:people_written], people_failed: @stats[:people_failed] }
  end
end
