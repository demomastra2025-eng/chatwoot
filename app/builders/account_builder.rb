# frozen_string_literal: true

class AccountBuilder
  include CustomExceptions::Account
  pattr_initialize [:account_name, :contact_phone, :company_size, :industry, :industry_other,
                    :email!, :confirmed, :user, :user_full_name, :user_password, :super_admin, :locale]

  def perform
    raise InvalidParams.new({}) if @account_name.to_s.strip.blank?

    if @user.nil?
      validate_email
      validate_user
    end
    ActiveRecord::Base.transaction do
      @account = create_account
      @user = create_and_link_user
    end
    [@user, @account]
  rescue StandardError => e
    Rails.logger.debug e.inspect
    raise e
  end

  private

  def user_full_name
    # users.name is required (v2 signup and some OAuth profiles send no name), so fall back to the email local part
    @user_full_name.presence || @email.to_s.split('@').first.to_s
  end

  def account_name = @account_name.to_s.strip

  def validate_email
    Account::SignUpEmailValidationService.new(@email).perform
  end

  def validate_user
    if User.exists?(email: @email)
      raise UserExists.new(email: @email)
    else
      true
    end
  end

  # A new account gets the base plan first (so the trial snapshot is taken from it), then the trial adds the trial
  # modules on top. When the trial ends, only the modules go away.
  def create_account
    @account = Account.create!(name: account_name, locale: I18n.locale)
    Accounts::ApplyPlan.new(account: @account, modules: []).call
    @account.activate_trial!
    @account.update!(custom_attributes: @account.custom_attributes.merge(
      'contact_phone' => @contact_phone.to_s.strip.presence,
      'company_size' => @company_size.to_s.strip.presence,
      'industry' => @industry.to_s.strip.presence,
      'industry_other' => (@industry_other.to_s.strip.presence if @industry.to_s == 'other')
    ).compact)
    Current.account = @account
  end

  def create_and_link_user
    if @user.present? || create_user
      link_user_to_account(@user, @account)
      @user
    else
      raise UserErrors.new(errors: @user.errors)
    end
  end

  def link_user_to_account(user, account)
    AccountUser.create!(
      account_id: account.id,
      user_id: user.id,
      role: AccountUser.roles['administrator']
    )
  end

  def create_user
    @user = User.new(email: @email,
                     password: user_password,
                     password_confirmation: user_password,
                     name: user_full_name)
    @user.type = 'SuperAdmin' if @super_admin
    @user.confirm if @confirmed
    @user.save!
  end
end
