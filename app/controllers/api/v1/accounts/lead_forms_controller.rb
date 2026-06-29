class Api::V1::Accounts::LeadFormsController < Api::V1::Accounts::LeadForms::BaseController
  before_action :check_admin_authorization?
  before_action :sync_widget_forms!, only: [:index]
  before_action :set_lead_form, only: [:show, :update, :destroy]

  def index
    forms = Current.account.lead_forms.includes(:inbox).ordered
    forms = forms.for_source(params[:source_kind]) if params[:source_kind].present?
    forms = forms.where(status: params[:status]) if params[:status].present?

    render_payload(
      forms.map { |form| ::LeadForms::PayloadBuilder.form(form) },
      meta: { count: forms.size }
    )
  end

  def show
    render_payload(::LeadForms::PayloadBuilder.form(@lead_form))
  end

  def create
    form = Current.account.lead_forms.create!(lead_form_params)
    render_payload(::LeadForms::PayloadBuilder.form(form), status: :created)
  end

  def update
    @lead_form.update!(lead_form_params)
    render_payload(::LeadForms::PayloadBuilder.form(@lead_form))
  end

  def destroy
    @lead_form.update!(status: 'archived')
    head :no_content
  end

  private

  def lead_form_params
    permitted = params.permit(
      :name,
      :description,
      :source_kind,
      :status,
      :external_ref,
      :inbox_id
    ).to_h
    permitted[:field_schema] = normalize_field_schema_param if params.key?(:field_schema)
    permitted[:settings] = normalize_hash_param(:settings) if params.key?(:settings)
    permitted
  end

  def normalize_field_schema_param
    raw_schema = params[:field_schema]
    items = raw_schema.is_a?(Array) ? raw_schema : raw_schema.try(:values)
    Array(items).map do |item|
      item = item.to_unsafe_h if item.respond_to?(:to_unsafe_h)
      item.to_h.deep_stringify_keys
    end
  end

  def normalize_hash_param(key)
    value = params[key]
    value = value.to_unsafe_h if value.respond_to?(:to_unsafe_h)
    value.to_h.deep_stringify_keys
  end

  def set_lead_form
    @lead_form = Current.account.lead_forms.find(params[:id])
  end

  def sync_widget_forms!
    ::LeadForms::WidgetSyncService.new(account: Current.account).perform
  end
end
