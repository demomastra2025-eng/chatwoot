class AccessControl::SystemRoleCatalog
  ROLE_NAMES = {
    'administrator' => 'Administrator',
    'department_lead' => 'Department Lead',
    'employee' => 'Employee',
    'commercial_director' => 'Commercial Director',
    'observer' => 'Observer'
  }.freeze
  EMPLOYEE_ALL_VIEW_RESOURCES = %w[contacts conversations appointments].freeze
  BOOTSTRAP_RESOURCES = AccessRoleGrant::RESOURCES.freeze
  SCOPED_BOOTSTRAP_RESOURCES = (BOOTSTRAP_RESOURCES - %w[automation_rules]).freeze

  class << self
    def grants_for(system_key)
      send("#{system_key}_grants")
    end

    private

    def administrator_grants
      grants_for_resources(BOOTSTRAP_RESOURCES, except: [], scope: 'all')
    end

    def department_lead_grants
      grants_for_resources(
        SCOPED_BOOTSTRAP_RESOURCES,
        except: %w[configure manage_finance override_schedule],
        scope: 'team'
      )
    end

    def employee_grants
      grants_for_resources(
        SCOPED_BOOTSTRAP_RESOURCES,
        except: %w[view_finance manage_finance view_configuration configure export view_reports override_schedule],
        scope: 'own'
      ).map do |grant|
        next grant.merge(access_scope: 'all') if grant[:capability] == 'view' &&
                                                 EMPLOYEE_ALL_VIEW_RESOURCES.include?(grant[:resource])
        next grant unless grant[:resource] == 'conversations' && grant[:capability] == 'take'

        grant.merge(access_scope: 'team')
      end
    end

    def commercial_director_grants
      grants_for_resources(%w[contacts deals tasks], except: %w[view_configuration configure], scope: 'all') +
        grants_for_resources(%w[conversations appointments], only: %w[view export view_reports], scope: 'all')
    end

    def observer_grants
      grants_for_resources(SCOPED_BOOTSTRAP_RESOURCES, only: %w[view], scope: 'all')
    end

    def grants_for_resources(resources, scope:, only: nil, except: [])
      resources.flat_map do |resource|
        capabilities = AccessRoleGrant::RESOURCE_CAPABILITIES.fetch(resource)
        capabilities &= only if only
        capabilities -= except
        capabilities.map { |capability| { resource: resource, capability: capability, access_scope: scope } }
      end
    end
  end
end
