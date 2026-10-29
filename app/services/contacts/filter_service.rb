class Contacts::FilterService < FilterService
  ATTRIBUTE_MODEL = 'contact_attribute'.freeze

  def initialize(account, user, params)
    @account = account
    # TODO: Change the order of arguments in FilterService maybe?
    # account, user, params makes more sense
    super(params, user)
  end

  def perform
    membership = resolve_account_membership
    return { contacts: @account.contacts.none, count: 0 } if @user.present? && membership.nil?

    payload = @params[:payload] || @params['payload']
    return { contacts: @account.contacts.none, count: 0 } if Contacts::IinPrivacy.restricted_filter?(payload, account_user: membership)

    validate_query_operator
    @contacts = query_builder(@filters['contacts'])

    {
      contacts: @contacts,
      count: @contacts.count
    }
  end

  def filter_values(query_hash)
    current_val = query_hash['values'][0]
    if query_hash['attribute_key'] == 'phone_number'
      "+#{current_val&.delete('+')}"
    elsif query_hash['attribute_key'] == 'country_code'
      current_val.downcase
    else
      current_val.is_a?(String) ? current_val.downcase : current_val
    end
  end

  def base_relation
    @account.contacts.resolved_contacts(use_crm_v2: @account.feature_enabled?('crm_v2'))
  end

  def filter_config
    {
      entity: 'Contact',
      table_name: 'contacts'
    }
  end

  private

  def resolve_account_membership
    return @user if @user.is_a?(AccountUser)
    return @account.account_users.find_by(user_id: @user.id) if @user.present?

    Current.account_user
  end

  def equals_to_filter_string(filter_operator, current_index)
    return "= :value_#{current_index}" if filter_operator == 'equal_to'

    "!= :value_#{current_index}"
  end
end
