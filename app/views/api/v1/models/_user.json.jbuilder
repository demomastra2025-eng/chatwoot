json.access_token resource.access_token.token
json.account_id resource.active_account_user&.account_id
json.available_name resource.available_name
json.avatar_url resource.avatar_url
json.confirmed resource.confirmed?
json.display_name resource.display_name
json.message_signature resource.message_signature
json.email resource.email
json.hmac_identifier resource.hmac_identifier if GlobalConfig.get('CHATWOOT_INBOX_HMAC_KEY')['CHATWOOT_INBOX_HMAC_KEY'].present?
json.id resource.id
json.inviter_id resource.active_account_user&.inviter_id
json.name resource.name
json.provider resource.provider
json.pubsub_token resource.pubsub_token
json.custom_attributes resource.custom_attributes if resource.custom_attributes.present?
json.role resource.active_account_user&.role
json.ui_settings resource.ui_settings
json.uid resource.uid
json.type resource.type
account_users = resource.account_users.to_a
associations = [:account, { access_role: :grants }]
associations << :custom_role if AccountUser.reflect_on_association(:custom_role)
ActiveRecord::Associations::Preloader.new(records: account_users, associations: associations).call
team_ids_by_account = TeamMember.joins(:team)
                                .where(user_id: resource.id, teams: { account_id: account_users.map(&:account_id) })
                                .pluck('teams.account_id', 'team_members.team_id')
                                .group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
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
    json.access_control_mode account_user.account.access_control_mode
    if account_user.account.access_control_mode == 'enforced'
      role = account_user.access_role
      grants = role&.account_id == account_user.account_id ? role.grants : []
      grants_by_resource = grants.reject(&:retired?).group_by(&:resource)
      json.crm_team_ids team_ids_by_account.fetch(account_user.account_id, [])
      json.crm_capabilities do
        %w[deals tasks].each do |resource|
          json.set! resource, (grants_by_resource.fetch(resource, []).filter_map { |grant| grant.capability if grant.access_scope != 'none' })
        end
      end
      json.crm_grant_scopes(
        grants_by_resource.slice('deals', 'tasks').transform_values { |items| items.to_h { |grant| [grant.capability, grant.access_scope] } }
      )
    end
    # the actual availability user has configured
    json.availability account_user.availability
    # availability derived from presence
    json.availability_status account_user.availability_status
    json.auto_offline account_user.auto_offline
    json.partial! 'api/v1/models/account_user', account_user: account_user if ChatwootApp.enterprise?
  end
end
