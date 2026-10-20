# frozen_string_literal: true

# What the page «Новый клиент» asks, every value as typed (text), so a form with a problem is drawn again with all of it.
#
#   form = SuperAdmin::ClientOnboarding::Form.blank          # the form as the page first shows it
#   form = SuperAdmin::ClientOnboarding::Form.from_params(params)   # the form of a request: only text is taken
SuperAdmin::ClientOnboarding::Form = Struct.new(
  :account_name, :timezone, :organization_mode, :organization_id, :organization_name, :organization_bin, :modules, :start_trial, :admin,
  keyword_init: true
) do
  # Astana, no organization, no modules, the invitation when the mail works and the password when it does not
  def self.blank
    admin = SuperAdmin::AccountMember::Input.new(
      mode: 'create', role: 'administrator', adopt: false, email: '', name: '', password: '',
      access: SuperAdmin::MailState.configured? ? 'invitation' : 'password'
    )
    new(account_name: '', timezone: SuperAdmin::AccountTimezones::DEFAULT, organization_mode: 'none', organization_id: '',
        organization_name: '', organization_bin: '', modules: [], start_trial: false, admin: admin)
  end

  # Anything that is not text (a list or a map where a field is expected) is an empty value
  def self.from_params(params)
    blank.tap { |form| form.read(params) }
  end

  def self.group(raw)
    return {} unless raw.respond_to?(:to_unsafe_h) || raw.is_a?(Hash)

    (raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw).transform_values { |value| value.is_a?(String) ? value : nil }
  end

  def self.module_list(raw)
    Array(raw.is_a?(Array) || raw.is_a?(String) ? raw : []).select { |value| value.is_a?(String) }
  end

  def read(params)
    read_account(self.class.group(params[:account]))
    read_organization(self.class.group(params[:organization]))
    read_plan(params)
    read_admin(self.class.group(params[:admin]))
  end

  private

  def read_account(account)
    self.account_name = account['name'].to_s
    self.timezone = account['timezone'].presence || timezone
  end

  def read_organization(organization)
    self.organization_mode = organization['mode'].presence || 'none'
    self.organization_id = organization['id'].to_s
    self.organization_name = organization['name'].to_s
    self.organization_bin = organization['bin'].to_s
  end

  def read_plan(params)
    self.modules = self.class.module_list(params[:modules])
    self.start_trial = ActiveModel::Type::Boolean.new.cast(params[:start_trial]) ? true : false
  end

  def read_admin(admin_params)
    self.admin = SuperAdmin::AccountMember::Input.from_params(admin_params, access: admin.access)
    # The first person of an account is a new administrator, whatever the request says
    admin.mode = 'create'
    admin.role = 'administrator'
  end
end
