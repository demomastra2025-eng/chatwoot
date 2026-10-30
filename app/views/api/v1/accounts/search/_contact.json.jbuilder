json.email contact.email
json.id contact.id
json.name contact.name
json.phone_number contact.phone_number
json.identifier Contacts::IinPrivacy.mask_identifier(contact.identifier)
json.additional_attributes Contacts::IinPrivacy.mask_attributes_hash(contact.additional_attributes)
json.last_activity_at contact.last_activity_at&.to_i
