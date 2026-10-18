# == Schema Information
#
# Table name: access_tokens
#
#  id         :bigint           not null, primary key
#  owner_type :string
#  token      :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  owner_id   :bigint
#
# Indexes
#
#  index_access_tokens_on_owner_type_and_owner_id  (owner_type,owner_id)
#  index_access_tokens_on_token                    (token) UNIQUE
#

class AccessToken < ApplicationRecord
  has_secure_token :token
  belongs_to :owner, polymorphic: true

  # What a screen may show of the token: the last 4 characters (SuperAdmin::SecretMask). The full value is shown once,
  # right after a partner access is created or its token is reissued, and nowhere else.
  def hint
    SuperAdmin::SecretMask.hint(token)
  end
end
