class AccessControl::LegacyCustomRoleMapper
  OPERATIONAL_CONVERSATION_CAPABILITIES = %w[view create update_fields assign transition take].freeze
  DEAL_MANAGE_CAPABILITIES = %w[view create update_fields assign transition delete_archive].freeze
  TASK_MANAGE_CAPABILITIES = %w[view create update_fields assign transition complete_cancel delete_archive].freeze

  PERMISSION_GRANTS = {
    'conversation_manage' => -> { grants('conversations', OPERATIONAL_CONVERSATION_CAPABILITIES, 'all') },
    'conversation_team_manage' => -> { grants('conversations', OPERATIONAL_CONVERSATION_CAPABILITIES, 'team') },
    'contact_manage' => -> { grants('contacts', %w[view create update_fields], 'all') },
    'crm_deal_view' => -> { grants('deals', %w[view], 'all') },
    'crm_deal_manage' => -> { grants('deals', DEAL_MANAGE_CAPABILITIES, 'all') },
    'crm_task_view' => -> { grants('tasks', %w[view], 'all') },
    'crm_task_manage' => -> { grants('tasks', TASK_MANAGE_CAPABILITIES, 'all') },
    'automation_manage' => -> { grants('automation_rules', %w[manage], 'all') }
  }.freeze

  Analysis = Data.define(:grants, :unsupported_permissions) do
    def mappable?
      unsupported_permissions.empty?
    end
  end

  def self.analyze(custom_role)
    permissions = custom_role.permissions.compact.uniq
    unsupported = permissions - PERMISSION_GRANTS.keys
    mapped_grants = permissions.filter_map { |permission| PERMISSION_GRANTS[permission]&.call }.flatten

    Analysis.new(grants: merge_grants(mapped_grants), unsupported_permissions: unsupported.sort)
  end

  def self.call(custom_role:, reconcile_grants: true)
    custom_role.account.with_lock do
      custom_role.lock!
      analysis = analyze(custom_role)
      raise ArgumentError, "Unsupported permissions: #{analysis.unsupported_permissions.join(', ')}" unless analysis.mappable?

      role = find_or_create_role(custom_role)
      reconcile_attributes(role, custom_role)
      grants_changed = reconcile_grants(role, analysis.grants) if reconcile_grants && role.legacy_grant_source?
      role.update!(updated_at: Time.current) if grants_changed
      role
    end
  end

  def self.grants(resource, capabilities, access_scope)
    capabilities.map { |capability| { resource: resource, capability: capability, access_scope: access_scope } }
  end
  private_class_method :grants

  def self.merge_grants(grants)
    scope_priority = AccessRoleGrant::ACCESS_SCOPES.each_with_index.to_h
    grants.group_by { |grant| [grant[:resource], grant[:capability]] }.map do |_, candidates|
      candidates.max_by { |grant| scope_priority.fetch(grant[:access_scope]) }
    end
  end
  private_class_method :merge_grants

  def self.find_or_create_role(custom_role)
    existing = AccessRole.find_by(legacy_custom_role_id: custom_role.id)
    return existing if existing

    AccessRole.create!(
      account: custom_role.account,
      legacy_custom_role: custom_role,
      name: unique_name(custom_role),
      description: custom_role.description
    )
  end
  private_class_method :find_or_create_role

  def self.reconcile_attributes(role, custom_role)
    attributes = {
      name: unique_name(custom_role, excluding_role_id: role.id),
      description: custom_role.description
    }
    role.update!(attributes) unless role.attributes.symbolize_keys.slice(*attributes.keys) == attributes
  end
  private_class_method :reconcile_attributes

  def self.unique_name(custom_role, excluding_role_id: nil)
    name = custom_role.name.to_s.strip
    return name unless reserved_or_used_name?(custom_role.account_id, name, excluding_role_id: excluding_role_id)

    imported_name = "#{name} (Imported #{custom_role.id})"
    suffix = 1
    while used_name?(custom_role.account_id, imported_name, excluding_role_id: excluding_role_id)
      suffix += 1
      imported_name = "#{name} (Imported #{custom_role.id}-#{suffix})"
    end
    imported_name
  end
  private_class_method :unique_name

  def self.reserved_or_used_name?(account_id, name, excluding_role_id: nil)
    reserved_names = AccessControl::SystemRoleCatalog::ROLE_NAMES.values.map(&:downcase)
    reserved_names.include?(name.downcase) || used_name?(account_id, name, excluding_role_id: excluding_role_id)
  end
  private_class_method :reserved_or_used_name?

  def self.used_name?(account_id, name, excluding_role_id: nil)
    roles = AccessRole.where(account_id: account_id)
    roles = roles.where.not(id: excluding_role_id) if excluding_role_id
    roles.exists?(['lower(name) = ?', name.downcase])
  end
  private_class_method :used_name?

  def self.reconcile_grants(role, definitions)
    expected = definitions.index_by { |grant| [grant[:resource], grant[:capability]] }
    changed = false
    role.grants.find_each do |grant|
      definition = expected.delete([grant.resource, grant.capability])
      if definition
        unless grant.access_scope == definition[:access_scope]
          grant.update!(access_scope: definition[:access_scope])
          changed = true
        end
      else
        grant.destroy!
        changed = true
      end
    end

    expected.each_value do |grant|
      role.grants.create!(grant.merge(account: role.account))
      changed = true
    end
    changed
  end
end
