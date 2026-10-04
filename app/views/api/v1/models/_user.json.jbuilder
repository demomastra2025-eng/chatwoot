impersonation_context = local_assigns[:impersonation_context].presence || @super_admin_impersonation
account_users = resource.account_users
if impersonation_context.present?
  account_users = account_users.where(account_id: impersonation_context['account_id'])
  account_user = account_users.first
else
  account_user = resource.active_account_user
end

json.access_token resource.access_token.token unless impersonation_context.present?
json.account_id account_user&.account_id
json.available_name resource.available_name
json.avatar_url resource.avatar_url
json.confirmed resource.confirmed?
json.display_name resource.display_name
json.message_signature resource.message_signature
json.email resource.email
json.hmac_identifier resource.hmac_identifier if impersonation_context.blank? && GlobalConfig.get('CHATWOOT_INBOX_HMAC_KEY')['CHATWOOT_INBOX_HMAC_KEY'].present?
json.id resource.id
json.inviter_id account_user&.inviter_id
json.name resource.name
json.provider resource.provider
json.pubsub_token impersonation_context.present? ? impersonation_context['pubsub_token'] : resource.pubsub_token
json.custom_attributes resource.custom_attributes if resource.custom_attributes.present?
json.role account_user&.role
json.ui_settings resource.ui_settings
json.uid resource.uid
json.type resource.type
json.accounts do
  json.array! account_users do |account_user|
    json.id account_user.account_id
    json.logo_url account_user.account.logo_url
    json.name account_user.account.name
    json.status account_user.account.status
    json.features account_user.account.enabled_features
    json.active_at account_user.active_at
    json.role account_user.role
    json.permissions account_user.permissions
    # the actual availability user has configured
    json.availability account_user.availability
    # availability derived from presence
    json.availability_status account_user.availability_status
    json.auto_offline account_user.auto_offline
    json.partial! 'api/v1/models/account_user', account_user: account_user if ChatwootApp.enterprise?
  end
end
