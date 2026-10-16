require 'administrate/base_dashboard'

class AccountDashboard < Administrate::BaseDashboard
  # ATTRIBUTE_TYPES
  # a hash that describes the type of each of the model's fields.
  #
  # Each different type represents an Administrate::Field object,
  # which determines how the attribute is displayed
  # on pages throughout the dashboard.

  enterprise_attribute_types = if ChatwootApp.enterprise?
                                 attributes = {
                                   limits: AccountLimitsField,
                                   account_usage_overview: AccountUsageField,
                                   limit_counter_excluded_user_ids_raw: CommaSeparatedIdsField
                                 }

                                 # Only show manually managed features in Chatwoot Cloud deployment
                                 attributes[:manually_managed_features] = ManuallyManagedFeaturesField if ChatwootApp.chatwoot_cloud?

                                 # Add all_features last so it appears after manually_managed_features
                                 attributes[:all_features] = AccountFeaturesField

                                 attributes
                               else
                                 {}
                               end

  # The language order of the form: the clinics of the platform speak Russian first, then Kazakh, then English.
  LOCALE_ORDER = %w[ru kk en].freeze

  # [["Русский", "ru"], ["Қазақша", "kk"], ["English", "en"]]: the select of the form shows the names of the languages
  def self.locale_options
    options = ENABLED_LANGUAGES_CONFIG.values.map do |language|
      code = language[:iso_639_1_code]
      [I18n.t("super_admin.locales.#{code}", default: language[:name]), code]
    end
    options.sort_by { |_name, code| LOCALE_ORDER.index(code) || LOCALE_ORDER.size }
  end

  # [["Активен", "active"], ["Заблокирован", "suspended"]]
  def self.status_options
    %w[active suspended].map { |status| [I18n.t("super_admin.accounts.statuses.#{status}"), status] }
  end

  ATTRIBUTE_TYPES = {
    id: Field::Number.with_options(searchable: true),
    name: Field::String.with_options(searchable: true),
    created_at: Field::DateTime,
    updated_at: Field::DateTime,
    users: CountField,
    conversations: CountField,
    # Lambdas: the names are looked up when the form is drawn, not when the class loads.
    locale: Field::Select.with_options(collection: -> { AccountDashboard.locale_options }),
    status: Field::Select.with_options(collection: -> { AccountDashboard.status_options }),
    account_users: Field::HasMany,
    custom_attributes: Field::String,
    # Only on the edit form. The change is not saved with the other fields: the controller links the account through
    # SuperAdmin::OrganizationLinks (see AccountsController#update).
    organization_id: OrganizationSelectField
  }.merge(enterprise_attribute_types).freeze

  # COLLECTION_ATTRIBUTES
  # an array of attributes that will be displayed on the model's index page.
  #
  # The clinic list draws its own table (app/views/super_admin/accounts/_collection.html.erb); these attributes only
  # decide what Administrate preloads and which column headers can sort.
  COLLECTION_ATTRIBUTES = %i[
    id
    name
    status
  ].freeze

  # SHOW_PAGE_ATTRIBUTES
  # an array of attributes that will be displayed on the model's show page.
  enterprise_show_page_attributes = if ChatwootApp.enterprise?
                                      attrs = %i[
                                        custom_attributes
                                        limit_counter_excluded_user_ids_raw
                                        limits
                                        account_usage_overview
                                      ]
                                      attrs << :manually_managed_features if ChatwootApp.chatwoot_cloud?
                                      attrs << :all_features
                                      attrs
                                    else
                                      []
                                    end
  SHOW_PAGE_ATTRIBUTES = (%i[
    id
    name
    created_at
    updated_at
    locale
    status
    conversations
    account_users
  ] + enterprise_show_page_attributes).freeze

  # FORM_ATTRIBUTES
  # an array of attributes that will be displayed
  # on the model's form (`new` and `edit`) pages.
  enterprise_form_attributes = if ChatwootApp.enterprise?
                                 attrs = %i[
                                   limit_counter_excluded_user_ids_raw
                                   limits
                                   account_usage_overview
                                 ]
                                 attrs << :manually_managed_features if ChatwootApp.chatwoot_cloud?
                                 attrs << :all_features
                                 attrs
                               else
                                 []
                               end
  FORM_ATTRIBUTES = (%i[
    name
    locale
    status
  ] + enterprise_form_attributes).freeze

  # A new clinic is created with a name and a language; the plan modules and the trial are chosen on the same page
  # (app/views/super_admin/accounts/new.html.erb) and applied right after the account is saved.
  FORM_ATTRIBUTES_NEW = %i[name locale].freeze

  # The edit form in three sections. The keys are the section legends (helpers.label.account.<key>).
  enterprise_limit_section = ChatwootApp.enterprise? ? %i[limits limit_counter_excluded_user_ids_raw account_usage_overview] : []
  enterprise_feature_section = if ChatwootApp.enterprise?
                                 ChatwootApp.chatwoot_cloud? ? %i[manually_managed_features all_features] : %i[all_features]
                               else
                                 []
                               end
  FORM_ATTRIBUTES_EDIT = {
    section_main: %i[name locale status organization_id],
    section_limits: enterprise_limit_section,
    section_features: enterprise_feature_section
  }.reject { |_section, section_attributes| section_attributes.empty? }.freeze

  # COLLECTION_FILTERS
  # a hash that defines filters that can be used while searching via the search
  # field of the dashboard.
  #
  # For example to add an option to search for open resources by typing "open:"
  # in the search field:
  #
  #   COLLECTION_FILTERS = {
  #     open: ->(resources) { resources.where(open: true) }
  #   }.freeze
  #
  # The plan filters follow the plans registry: accounts with no plan, with the base plan, and one filter per module.
  MODULE_FILTERS = Accounts::Plans.module_keys.to_h do |module_key|
    [
      :"module_#{module_key}",
      ->(resources) { resources.where("custom_attributes->'plan_modules' @> ?::jsonb", [module_key].to_json) }
    ]
  end.freeze

  PLAN_FILTERS = {
    no_plan: ->(resources) { resources.where("custom_attributes->>'plan' IS NULL") },
    plan_base: ->(resources) { resources.where("custom_attributes->>'plan' = ?", Accounts::Plans::BASE_KEY) },
    **MODULE_FILTERS
  }.freeze

  # The order is the order of the segmented control above the list:
  # status, trial, plan (none, base, one per module), then the rest.
  COLLECTION_FILTERS = {
    active: ->(resources) { resources.where(status: :active) },
    suspended: ->(resources) { resources.where(status: :suspended) },
    trial_active: lambda { |resources|
      resources.where(
        "custom_attributes->>'plan_type' = 'trial' AND (custom_attributes->>'trial_expires_at')::timestamp > ?",
        Time.current
      )
    },
    trial_expired: lambda { |resources|
      resources.where(
        "custom_attributes->>'plan_type' = 'trial' AND " \
        "(custom_attributes->>'trial_expires_at' IS NULL OR (custom_attributes->>'trial_expires_at')::timestamp <= ?)",
        Time.current
      )
    },
    **PLAN_FILTERS,
    recent: ->(resources) { resources.where('created_at > ?', 30.days.ago) },
    storage_high: lambda { |resources|
      resources.where(
        "COALESCE((limits->>'storage_bytes')::numeric, 0) > 0 AND " \
        'COALESCE((SELECT SUM(b.byte_size) FROM active_storage_attachments a ' \
        'JOIN active_storage_blobs b ON b.id = a.blob_id ' \
        'JOIN attachments att ON att.id = a.record_id ' \
        "WHERE a.record_type = 'Attachment' AND att.account_id = accounts.id), 0) >= (COALESCE((limits->>'storage_bytes')::numeric, 0) * 0.8)"
      )
    },
    marked_for_deletion: ->(resources) { resources.where("custom_attributes->>'marked_for_deletion_at' IS NOT NULL") }
  }.freeze

  # Overwrite this method to customize how accounts are displayed
  # across all pages of the admin dashboard.
  #
  def display_resource(account)
    "##{account.id} #{account.name}"
  end

  # We do not use the action parameter but we still need to define it
  # to prevent an error from being raised (wrong number of arguments)
  # Reference: https://github.com/thoughtbot/administrate/pull/2356/files#diff-4e220b661b88f9a19ac527c50d6f1577ef6ab7b0bed2bfdf048e22e6bfa74a05R204
  def permitted_attributes(action)
    # The status is not on the new-clinic form, but a request that sends it keeps working.
    attrs = super + [:status, { limits: {} }]
    attrs << :limit_counter_excluded_user_ids_raw if ChatwootApp.enterprise?

    # Add manually_managed_features to permitted attributes only for Chatwoot Cloud
    attrs << { manually_managed_features: [] } if ChatwootApp.chatwoot_cloud?

    attrs.uniq
  end
end
