# M5(b) trigger: a contact's primary number changed away (dashboard edit, MedElement field resolution, channel update,
# or the contact was deleted). Every contact that has that number as доп. номер gets a promotion hint.
class Contacts::SharedPhoneReleasedJob < ApplicationJob
  queue_as :medium
  # The released number never appears in job logs or in the queue payload (retries, dead set, error reports): it is
  # passed encrypted with a key derived from secret_key_base, and arguments are not logged.
  self.log_arguments = false

  def self.enqueue(account_id:, phone:, previous_holder_id:)
    perform_later(account_id, encryptor.encrypt_and_sign(phone), previous_holder_id)
  end

  def self.encryptor
    key = Rails.application.key_generator.generate_key('contacts/shared_phone_released_job', ActiveSupport::MessageEncryptor.key_len)
    ActiveSupport::MessageEncryptor.new(key)
  end

  def perform(account_id, sealed_phone, previous_holder_id)
    phone = self.class.encryptor.decrypt_and_verify(sealed_phone)
    return if phone.blank?

    Contacts::SharedPhoneHint.create_for_release!(account_id: account_id, phone: phone, previous_holder_id: previous_holder_id)
  end
end
