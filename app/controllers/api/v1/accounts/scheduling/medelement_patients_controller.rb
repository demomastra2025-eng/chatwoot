class Api::V1::Accounts::Scheduling::MedelementPatientsController < Api::V1::Accounts::Scheduling::BaseController
  before_action :ensure_patient_context_employee!
  before_action :set_directory

  def search
    render_payload(@directory.search(request_body_value!(:query)))
  end

  def create
    contact = @directory.import(request_body_value!(:token))
    render_payload(Scheduling::PayloadBuilder.contact(contact))
  end

  private

  def set_directory
    adapter = Scheduling::ProviderCommands::Registry.resolve!(account: Current.account, provider: 'medelement', require_hook: true)
    @directory = Integrations::Medelement::PatientDirectorySearch.new(account: Current.account, hook: adapter.hook, user: Current.user)
  end

  def request_body_value!(key)
    raise ActionController::ParameterMissing, key unless request.media_type == 'application/json'

    body = JSON.parse(request.raw_post)
    raise ActionController::ParameterMissing, key unless body.is_a?(Hash)

    body.fetch(key.to_s) { raise ActionController::ParameterMissing, key }
  rescue JSON::ParserError
    raise ActionController::ParameterMissing, key
  end
end
