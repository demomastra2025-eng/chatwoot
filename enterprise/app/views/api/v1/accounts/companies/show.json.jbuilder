json.payload do
  json.partial! 'company', company: @company
  json.contacts do
    json.array! @company_contacts do |contact|
      json.partial! 'api/v1/models/contact', formats: [:json], resource: contact
    end
  end
end
