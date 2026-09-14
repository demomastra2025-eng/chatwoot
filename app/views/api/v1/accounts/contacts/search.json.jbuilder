json.meta do
  json.count @contacts_count
  json.current_page @current_page
  json.has_more @has_more
end

participating_contact_ids = CommunicationThreadParticipant
                            .joins(:communication_thread)
                            .where(account_id: Current.account.id, user_id: Current.user.id)
                            .where(communication_threads: { contact_id: @contacts.map(&:id) })
                            .pluck('communication_threads.contact_id')

json.payload do
  json.array! @contacts do |contact|
    json.partial! 'api/v1/models/contact', formats: [:json], resource: contact, with_contact_inboxes: @include_contact_inboxes
    json.current_user_participant participating_contact_ids.include?(contact.id)
  end
end
