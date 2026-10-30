class Api::V1::Accounts::Contacts::PhonesController < Api::V1::Accounts::Contacts::BaseController
  before_action -> { authorize @contact, :update? }
  around_action :with_contact_actor

  def create
    @contact = service.add!(
      raw_phone: params[:phone_number].presence || params[:phone],
      label: params[:label],
      link_shared: ActiveModel::Type::Boolean.new.cast(params[:link_shared])
    )
    render 'api/v1/accounts/contacts/show', formats: [:json], status: :created
  rescue Contacts::PhoneManagementService::Error => e
    render_phone_error(e)
  end

  def set_primary
    @contact = service.set_primary!(phone_id: params[:id])
    render 'api/v1/accounts/contacts/show', formats: [:json]
  rescue Contacts::PhoneManagementService::Error => e
    render_phone_error(e)
  end

  def destroy
    @contact = service.remove!(phone_id: params[:id])
    render 'api/v1/accounts/contacts/show', formats: [:json]
  rescue Contacts::PhoneManagementService::Error => e
    render_phone_error(e)
  end

  private

  def service
    @service ||= Contacts::PhoneManagementService.new(
      account: Current.account,
      contact: @contact,
      actor: Current.user
    )
  end

  def with_contact_actor
    previous_actor = Current.executed_by
    Current.executed_by = Current.user if Current.user.present?
    @include_contact_inboxes = true
    yield
  ensure
    Current.executed_by = previous_actor
  end

  def render_phone_error(error)
    render json: { code: error.code, error: error.message }.merge(error.details.to_h), status: error.status
  end
end
