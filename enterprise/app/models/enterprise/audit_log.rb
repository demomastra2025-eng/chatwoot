# == Schema Information
#
# Table name: audits
#
#  id              :bigint           not null, primary key
#  action          :string
#  associated_type :string
#  auditable_type  :string
#  audited_changes :jsonb
#  comment         :string
#  remote_address  :string
#  request_uuid    :string
#  user_type       :string
#  username        :string
#  version         :integer          default(0)
#  created_at      :datetime
#  associated_id   :bigint
#  auditable_id    :bigint
#  user_id         :bigint
#
# Indexes
#
#  associated_index              (associated_type,associated_id)
#  auditable_index               (auditable_type,auditable_id,version)
#  index_audits_on_created_at    (created_at)
#  index_audits_on_request_uuid  (request_uuid)
#  user_index                    (user_id,user_type)
#
class Enterprise::AuditLog < Audited::Audit
  after_save :log_additional_information

  private

  def log_additional_information
    # rubocop:disable Rails/SkipsModelValidations
    if auditable_type == 'Account' && auditable_id.present?
      update_columns(associated_type: auditable_type, associated_id: auditable_id, username: actor_username)
    else
      update_columns(username: actor_username)
    end
    # rubocop:enable Rails/SkipsModelValidations
  end

  # The e-mail of the person who did it. The actor is not always a person with an e-mail: a partner access of the
  # Platform API (PlatformApp) has none, and an entry without an actor keeps the name written into `username`.
  def actor_username
    user.try(:email).presence || username
  end
end
